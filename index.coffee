AlchemyAPI = require('./alchemyapi')
Hapi = require('hapi')

async = require('async')
cfenv = require('cfenv')
pluralize = require('pluralize')

alchemyapi = new AlchemyAPI()
appEnv = cfenv.getAppEnv()
server = new Hapi.Server()
server.connection(
  host: appEnv.bind
  port: appEnv.port
)

# remove plurals
# remove dedupes
# get related links

prepare = (data, callback) ->
  dupes = []
  output = []
  exists = (item) ->
    name = pluralize(item.text.toLowerCase(), 1)
    if dupes.indexOf(name) == -1
      dupes.push(name)
      return false

    return true
     
  async.auto({
    concepts: (callback) ->
      for v in data['concepts']
        if !exists(v)
          i =
            text: pluralize(v.text.toLowerCase(), 1)
            relevance: parseFloat(v.relevance)
            group: 'concepts'
          output.push(i)

      callback()
    entities: ['concepts', (callback) ->
      for v in data['entities']
        if !exists(v)
          i =
            text: pluralize(v.text.toLowerCase(), 1)
            relevance: parseFloat(v.relevance)
            group: 'entities'
          output.push(i)

      callback()
    ]
    keywords: ['entities', (callback) ->
      for v in data['keywords']
        if !exists(v)
          i =
            text: pluralize(v.text.toLowerCase(), 1)
            relevance: parseFloat(v.relevance)
            group: 'keywords'
          output.push(i)

      callback()
    ]
  },
  (err, results) ->
    if err
      console.error(err)
      return callback(err)

    return callback(null, output)
  )

slides = (request, reply) ->
  async.auto({
    concepts: (callback) ->
      concepts(request, reply, callback)
    entities: (callback) ->
      entities(request, reply, callback)
    keywords: (callback) ->
      keywords(request, reply, callback)
  },
  (err, results) ->
    if err
      console.error(err)
      return reply(err)

    prepare(results, (err, output) ->
      if err
        console.error(err)
        return reply(err)

      return reply(output)
    )
  )

entities = (request, reply, next) ->
  threshold = 0.20

  if request.payload.entities_threshold
    threshold = request.payload.entities_threshold

  options =
    maxRetrieve: 999999
    quotations: true

  alchemyapi.entities('text', request.payload.text, options,
    (response) ->
      output = []
      filter = (item, callback) ->
        if parseFloat(item.relevance) > threshold
          return callback(true)
        else
          return callback(false)

      async.filter(response['entities'], filter, (results) ->
        next(null, results)
      )
  )

keywords = (request, reply, next) ->
  threshold = 0.40

  if request.payload.keywords_threshold
    threshold = request.payload.keywordss_threshold

  alchemyapi.keywords('text', request.payload.text, {},
    (response) ->
      output = []
      filter = (item, callback) ->
        if parseFloat(item.relevance) > threshold
          return callback(true)
        else
          return callback(false)

      async.filter(response['keywords'], filter, (results) ->
        next(null, results)
      )
  )

concepts = (request, reply, next) ->
  alchemyapi.concepts('text', request.payload.text, { maxRetrieve : 999999 },
    (response) ->
      next(null, response['concepts'])
  )

server.route(
  method: 'POST',
  path: '/slides',
  handler: (request, reply) ->
    slides(request, reply)
  config:
    payload:
#      override: 'application/json'
      output: 'data'
)

server.start()
