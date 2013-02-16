#node-redis-record

Simple ORM mapper for Redis written in coffee-script

	npm install redis-record

#Features

- 1:N & N:1 relationships
- key lookup 
- unique key generation
	

#Example usage

	class User extends RedisRecord

	  @hasMany:    ["messages"]
	  @belongsTo:  ["application"]
	  @lookUpBy:   ["key"]
	  @hasUniqKey: true

	module.exports = User
	

###Get all objects of certain type:

	User.all (err, reply) ->
	
###Get object by ID

	User.find <id>, (err, reply) ->
	

###Get object by attribute

	User.findBy "key", <some_key>, (err, reply) ->
	
###Get number of object of type

	User.count (err, reply) ->
	
###Create new object

	User.create object, (err, reply) ->
	
###Find or create object

	User.findOrCreate object, (err, reply) ->
	
Tries to find object by id included in object otherwise creates a new one
	

###Save object
	
	object.save (err, reply) ->  
	
###Delete object
	
	object.delete (err, reply) ->  
	
	
###Get attribute of object
	
  	object.get <attr_name>  

###Get attribute of object
	
    object.set <attr_name>, <attr_value>


©2013 Matthias Leitner and available under the MIT license:

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.