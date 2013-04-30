redis      = require("redis")
inflection = require("inflection")
bases      = require("bases")
crypto     = require("crypto")
_          = require("underscore")

# Class for handling persistence through redis
#
#
class RedisRecord
  class Config
    constructor: (@_config = {}) ->
    get: (attr = null) ->
      if attr
        config_attr = @_config[attr]
        unless config_attr
          setterName = inflection.camelize(attr)
          throw "No #{setterName} set - use RedisRecord.set#{setterName} to set it"
        config_attr
      else
        @_config
    set: (attr, value) ->
      @_config[attr] = value

  _config = null
  _config ?= new Config()

  @setConfig: (config) ->
    _config = new Config(config)
  @getConfig: ->
    _config

  @getNamespace: ->
    namespace = _config.get("namespace")
    if !namespace
      ""
    else
      "#{namespace}:"


  @setNamespace: (namespace) ->
    _config.set("namespace", namespace)

  @setNamespace("")

  @setModelLoadPath: (load_path) ->
    _config.set("model_load_path", load_path)
  @getModelLoadPath: ->
    if _config
      _config.get("model_load_path")
    else
      throw "No model load path set - use RedisRecord.setModelPath to define the path where your models are"


  # lua script used to fetch multiple instances of object
  list_lookup = """
                -- fetch all assoc ids
                local ids = redis.call("ZRANGE", ARGV[2], 0, -1)

                local result = {}
                local hashValue = nil

                -- generate correct namespace
                local namespace = ARGV[3]..ARGV[1].."|"

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

  @uniqKeyLength: 32

  @hasMany: []
  @belongsTo: []
  @hasAndBelongsToMany: []
  @lookUpBy: []

  # Constructor
  #
  #
  constructor: (@obj) ->
    #assign shorthand for class methods
    klass = @constructor

    # generate uniq key if defined
    if klass.hasUniqKey
      unless obj.key
        obj.key = klass.generateKey(klass.uniqKeyLength)

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

    @set("createdAt",new Date()) unless @get("createdAt")

    if @id == undefined || @id == null
      @_nextId (id) =>
        @id = id

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
    db.eval list_lookup, 0, @_name(), @_indexKey(), @getNamespace(), (err, reply) =>
      cb err, @_arrayReplyToObjects(reply)

    #cN = @_name()
    #db.sort "#{cN}_ids", "by", "#{cN}|*->id", "get", "#{cN}|*->name", "get", "#{cN}|*->createdAt","get", "#{cN}|*->updatedAt", (err, reply) =>

  # Public: find and load instance for given id
  #
  #
  @find: (id, cb) ->
    return unless id

    if id.length != @uniqKeyLength && !isNaN(id)
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
    assocId = @get("#{assoc}Id")
    className = inflection.pluralize(klass._name())
    "#{klass.getNamespace()}#{className}_for_#{assoc}|#{assocId}"

  _hasManyKey: (assoc)->
    "#{klass.getNamespace()}#{assoc}_for_#{@constructor.name.toLowerCase()}|#{@id}"

  # Private: generate id for next instance
  #
  #
  _nextId: (cb) ->
    db.INCR klass._countKey(), (err, val) =>
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
    for assoc in klass.hasAndBelongsToMany
      do (assoc) =>
        if @obj["#{assoc}Ids"]
          if mode == "add"
            db.ZADD @_assocKey(assoc), @id, @id, cb
          else

    for assoc in klass.belongsTo
      do (assoc) =>
        if @obj["#{assoc}Id"]
          if mode == "add"
            db.ZADD @_assocKey(assoc), @id, @id, cb
          else
            db.ZREM @_assocKey(assoc), @id, cb


  _maintainLookupKeys: (mode) ->
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


  # Private: generate getter methods for associated models
  #
  #
  @_generateAssociationMethods: ->
    @_gernateHasManyMethods()
    @_gernateBelongsToMethods()

  @_gernateBelongsToMethods: ->
    for assoc in @belongsTo
      do (assoc) =>
        unless @::[assoc]
          @::[assoc] = (cb) ->
            assocKey = "#{assoc}Id"
            if @obj[assocKey]
              # go out of node-modules directory
              require("../../../#{klass.getModelLoadPath()}/#{assoc}").find @obj[assocKey], cb
              #db.HGETALL "#{assoc}|#{@obj[assocKey]}", cb

  @_gernateHasManyMethods: ->
    for assoc in @hasMany
      do (assoc) =>
        className = inflection.singularize assoc
        unless @::[assoc]
          @::[assoc] = (cb) ->
            unless @id == undefined
              db.eval list_lookup, 0, className, @_hasManyKey(assoc), klass.getNamespace(), (err, reply) =>
                cb err, klass._arrayReplyToObjects(reply, assoc)

        countMethodName = "#{assoc}Count"

        unless @::[countMethodName]
          console.log "generating count method #{countMethodName}"
          @::[countMethodName] = (cb) ->
            console.log "getting lengt of #{@_hasManyKey(assoc)}"
            db.ZCARD @_hasManyKey(assoc), (err, count) =>
              cb err, count


                #fetch ids via sort - replaced by eval
                #db.sort @_hasManyKey(assoc), "get", "#{cN}|*->createdAt", cb

  # Private: generate objects from array redis reply
  #
  #
  @_arrayReplyToObjects: (reply, objectClass = klass.name) ->
    # map array of redis replies to objects
      if reply
        className = inflection.singularize(objectClass.toLowerCase())
        Model = require("../../../#{@getModelLoadPath()}/#{className}")
        reply = reply.map (obj) =>
          new Model(db.reply_to_object(obj))


      reply

  @_name: ->
    @name.toLowerCase()

  @_namespaced_name: ->
    "#{@getNamespace()}#{@_name()}"

  # Private: redis key for object
  #
  #
  @_dbKey: (id) ->
    "#{@_namespaced_name()}|#{id}"

  # Private: redis key holding number of objects for model
  #
  #
  @_countKey: (id) ->
    "#{@_namespaced_name()}|count"

  # Private: redis key for set holding object index
  #
  #
  @_indexKey: ->
    "#{@_namespaced_name()}_ids"

  @_lookUpKey: (key,value) ->
    "#{@_namespaced_name()}|#{key}|#{value}"

module.exports = RedisRecord