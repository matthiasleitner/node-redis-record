redis      = require("redis")
inflection = require("inflection")
bases      = require("bases")
crypto     = require("crypto")
_          = require("underscore")

# Class for handling persistence through redis
#
#
class RedisRecord

  config = null

  class Config
    constructor: (@config) ->
    get: -> @config
  @setModelPath: (load_path) ->
    config ?= new Config(load_path)
  @getModelPath: ->
    if config
      config.get()
    else
      throw "No model load path set - use RedisRecord.setModelPath to define the path where your models are"


  # lua script used to fetch multiple instances of object
  list_lookup = """
                -- fetch all assoc ids
                local ids = redis.call("ZRANGE", ARGV[2], 0, -1)

                local result = {}
                local hashValue = nil

                -- generate correct namespace
                local namespace = ARGV[1].."|"

                for i,v in ipairs(ids) do
                  hashValue = redis.call("HGETALL", namespace..v)
                  table.insert(hashValue, "id")
                  table.insert(hashValue, v)
                  result[i] = hashValue
                end
                return result
               """

  # init redis connection
  db = redis.createClient()

  klass = null

  # Constructor
  #
  #
  constructor: (@obj) ->
    #assign shorthand for class methods
    klass = @constructor

    # generate uniq key if defined
    if klass.hasUniqKey
      unless obj.key
        obj.key = klass.generateKey()

    @id = obj.id

    klass._generateAssociationMethods()


  # Public: getter for instance id
  #
  #
  id: ->
    @id

  # Public: Universial getter for instance attributes
  #
  #
  get: (attr) ->
    @obj[attr]

  set: (attr, value) ->
    @obj[attr] = value

  # Public: Delete object from redis
  #
  #
  delete: (cb) ->
    console.log "delete #{klass._name()} with id: #{@id}"

    # delete actual object hash
    db.DEL @_dbKey(), (err, reply) =>

      # delete from class index
      db.ZREM klass._indexKey(), @id, cb

    @_removeAssociations()

  # Public: Persist object
  #
  #
  save: (cb, create = false) ->
    # new object
    if @id == undefined || @id == null
      @_nextId (id) =>
        @id = id
        @obj.createdAt = new Date()

        # once ID is fetched call save again
        @save(cb, true)
    else
      @_stripFalsyValues()

      @obj.updatedAt = new Date()

      db.HMSET @_dbKey(), klass.stringifyAttributes(@obj), (err, reply) =>
        if !err
          if create
            @_afterCreate cb
          else
            cb null, reply if typeof cb == "function"
        else
          cb err, null

  toString: ->
    JSON.stringify(@obj)

  toJSON: ->
    @obj


  # ---------------------------------------------------------
  # static methods
  # ---------------------------------------------------------

  @create: (obj, cb) ->
    new this(obj).save(cb, true)

  # Public: fetch all instances of class from database
  #
  #
  @all: (cb) ->
    db.eval list_lookup, 0, @_name(), @_indexKey(), (err, reply) =>
      cb err, @_arrayReplyToObjects(reply)

    #cN = @_name()
    #db.sort "#{cN}_ids", "by", "#{cN}|*->id", "get", "#{cN}|*->name", "get", "#{cN}|*->createdAt","get", "#{cN}|*->updatedAt", (err, reply) =>

  # Public: find and load instance for given id
  #
  #
  @find: (id, cb) ->
    return unless id

    if id.length != 32 && !isNaN(id)
      db.HGETALL @_dbKey(id), (err, obj) =>
        if obj
          obj.id = id
          cb null, new this(obj)
        else
          cb err, null
    else
      @findBy "key", id, cb

  @findOrCreate: (obj, cb) ->
    if obj.id
      @find obj.id, (err, reply) =>
        if !reply
          @create obj, cb
        else
          cb err, reply
    else
      @create obj, cb


  # Public: find and load instance for given id
  #
  #
  @findBy: (key, value, cb) ->
    if _.contains(@lookUpBy, key)
      # get ID for lookup key
      db.GET @_lookUpKey(key, value), (err, reply) =>
        if reply
          @find reply, cb
        else
          cb err, reply
    else
      cb "key not available for lookup", null

  # Public: fetch total number of instances of class from database
  #
  #
  @count: (cb) ->
    db.get @_countKey(), cb

  # Convert attributes of object to be stored as redis hash
  #
  #
  @stringifyAttributes: (obj) ->
    sObj = {}
    for k,v of obj
      sObj[k] = "#{v}"
    sObj

  # Generate unique random Base62 key
  #
  #
  @generateKey: (length = 32) ->

    maxNum = Math.pow(62, length)
    numBytes = Math.ceil(Math.log(maxNum) / Math.log(256))

    loop
      bytes = crypto.randomBytes(numBytes)
      num = 0
      i = 0

      while i < bytes.length
        num += Math.pow(256, i) * bytes[i]
        i++
      break unless num >= maxNum

    bases.toBase62 num


  # ---------------------------------------------------------
  # private methods
  # ---------------------------------------------------------

  _assocKey: (assoc) ->
    cN = inflection.pluralize klass._name()
    assocId = @obj["#{assoc}Id"]
    "#{cN}_for_#{assoc}|#{assocId}"

  _hasManyKey: (assoc)->
    "#{assoc}_for_#{klass._name()}|#{@id}"

  # Private: generate id for next instance
  #
  #
  _nextId: (cb) ->
    db.INCR "#{klass._name()}|count", (err, val) =>
      cb(val)

  _afterCreate: (cb) ->
    console.log "stored #{klass._name()} with id: #{@id} "
    db.ZADD klass._indexKey(), @id, @id, (err, reply) =>
      @obj.id = @id

      @_applyAssociations()
      # pass copy of object to callback
      cb err, _.clone(@)

  _applyAssociations: (cb) ->
    @_handleAssociations cb, "add"

  _removeAssociations: (cb) ->
    @_handleAssociations cb, "remove"

  # Private: maintain associations on object creation and removal
  #
  #
  _handleAssociations: (cb, mode) ->
    if @id
      @_maintainAssociationReferences(cb, mode)
      @_maintainLookupKeys(mode)

  _maintainAssociationReferences: (cb, mode) ->
    if klass.belongsTo
      for assoc in klass.belongsTo
        do (assoc) =>
          if @obj["#{assoc}Id"]
            if mode == "add"
              db.ZADD @_assocKey(assoc), @id, @id, cb
            else
              db.ZREM @_assocKey(assoc), @id, cb


  _maintainLookupKeys: (mode) ->
    if klass.lookUpBy
      for key in klass.lookUpBy
        do (key) =>
          if @obj[key]
            if mode == "add"
              db.SET klass._lookUpKey(key, @obj[key]), @id, (err, reply) ->
                if err
                  console.log "error"
            else
              db.DEL klass._lookUpKey(key, @obj[key])

  # Private: redis key for current instance
  #
  #
  _dbKey: ->
    klass._dbKey @id


  # Private: strip false, null values from object before save
  #
  #
  _stripFalsyValues: ->
    _.each @obj, (v, k) =>
      delete @obj[k] unless v

  @_lookUpKey: (key,value) ->
    "#{@_name()}|#{key}|#{value}"


  # Private: generate getter methods for associated models
  #
  #
  @_generateAssociationMethods: ->
    @_gernateHasManyAssociationsMethods()
    @_gernateBelongsToAssociationsMethods()

  @_gernateBelongsToAssociationsMethods: ->
    if @belongsTo
      for assoc in @belongsTo
        do (assoc) =>
          unless @::[assoc]
            @::[assoc] = (cb) ->
              assocKey = "#{assoc}Id"
              if @obj[assocKey]
                # go out of node-modules directory
                require("../../../#{klass.getModelPath()}/#{assoc}").find @obj[assocKey], cb
                #db.HGETALL "#{assoc}|#{@obj[assocKey]}", cb

  @_gernateHasManyAssociationsMethods: ->
    if @hasMany
      for assoc in @hasMany
        do (assoc) =>
          unless @::[assoc]
            @::[assoc] = (cb) ->
              unless @id == undefined
                cN = inflection.singularize assoc
                db.eval list_lookup, 0, cN, @_hasManyKey(assoc), (err, reply) =>
                  cb err, klass._arrayReplyToObjects(reply)

                #fetch ids via sort - replaced by eval
                #db.sort @_hasManyKey(assoc), "get", "#{cN}|*->createdAt", cb

  # Private: generate objects from array redis reply
  #
  #
  @_arrayReplyToObjects: (reply) ->
    # map array of redis replies to objects
      if reply
        reply = reply.map (obj)->
          db.reply_to_object(obj)

      reply

  @_name: ->
    @name.toLowerCase()

  # Private: redis key for object
  #
  #
  @_dbKey: (id) ->
    "#{@_name()}|#{id}"

  # Private: redis key holding number of objects for model
  #
  #
  @_countKey: (id) ->
    "#{@_name()}|count"

  # Private: redis key for set holding object index
  #
  #
  @_indexKey: ->
    "#{@_name()}_ids"



module.exports = RedisRecord