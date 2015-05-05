AlchemyAPI = require('./alchemyapi')
Hapi = require('hapi')

async = require('async')
cfenv = require('cfenv')
path = require('path')
pluralize = require('pluralize')
request = require('request')
watson = require('watson-developer-cloud')

# setup
vcapCreds = (name) ->
  if process.env.VCAP_SERVICES
    services = JSON.parse(process.env.VCAP_SERVICES)
    if services[name]
      service = services[name][0]
      return {
        url: service.credentials.url,
        username: service.credentials.username,
        password: service.credentials.password
      }

    return {}

ciCredentials = vcapCreds('concept_insights')
ciCredentials.version = 'v1'
concept_insights = watson.concept_insights(ciCredentials)

alchemyapi = new AlchemyAPI()
appEnv = cfenv.getAppEnv()
server = new Hapi.Server()
server.connection(
  host: appEnv.bind
  port: appEnv.port
)

# app

build = (item, callback) ->
  if item.id
    i =
      text: pluralize(item.result.label, 1)
      description: ''
      image_url: ''
      relevance: 1.0
      content: []
  else
    i =
      text: pluralize(item.text, 1)
      description: ''
      image_url: ''
      relevance: parseFloat(item.relevance)
      content: []

  payload =
    func: 'labelSearch'
    limit: 10
    prefix: true
    concepts: true
    query: i.text
    user: 'public'
    corpus: 'ibmresearcher'

  async.auto({
    concept: (cb) ->
      concept_insights.labelSearch(payload, (err, labels) ->
        if err
          console.err(err)
          return cb(err)

        return cb(null, labels)
      )
   news: (cb) ->
    key = alchemyapi.apikey
    opts =
      method: 'GET'
      uri: 'https://access.alchemyapi.com/calls/data/GetNews'
      json: true
      qs:
        apikey: key
        outputMode: 'json'
        start: 'now-1d'
        end: 'now'
        maxResults: 50
        'q.enriched.url.title': i.text
        return: 'enriched.url.title,enriched.url.text,enriched.url.image,enriched.url.url'

    request(opts, (err, response, body) ->
      if err
        return cb(null, []) 

      if response.statusCode != 200
        return cb(null, [])

      return cb(null, body.result.docs)
    )
  },
  (err, results) ->
    if results['concept']
      l = results['concept'][0]
      c =
        headline: l.result.abstract
        type: 'wiki'
        image_url: l.result.thumbnail
        url: l.result.link

      i.content.push(c)

    if results['news']
      for v in results['news']
        l = v.source.enriched.url
        c =
          headline: l.title
          type: 'news'
          image_url: l.image
          url: l.url

        if c.image_url
          i.content.push(c)

    return callback(null, i)
  )

prepare = (data, callback) ->
  linkedTypes = [
    'website'
    'geo'
    'dbpedia'
    'yago'
    'opencyc'
    'freebase'
    'ciaFactbook'
    'census'
    'geonames'
    'crunchbase'
  ]

  dupes = []
  exists = (item) ->
    if item.id
      name = pluralize(item.result.label, 1)
    else
      name = pluralize(item.text.toLowerCase(), 1)
    if dupes.indexOf(name) == -1
      dupes.push(name)
      return false

    return true
     
  async.auto({
    concepts: (callback) ->
      #return callback(null, [])
      async.map(data['concepts'], build, callback)
    entities: (callback) ->
      #return callback(null, [])
      async.map(data['entities'], build, callback)
    keywords: (callback) ->
      #return callback(null, [])
      async.map(data['concepts'], build, callback)
    insights: (callback) ->
      if data['insights'].length > 0
        i = [data['insights'][0]]
      else
        i = data['insights']
      async.map(i, build, callback)

  },
  (err, results) ->
    if err
      console.error(err)
      return callback(err)

    endpoints = ['concepts', 'entities', 'keywords', 'insights']
    output = []
    missing = results['concepts'].length == 0 and results['entities'].length == 0 and results['keywords'].length == 0

    for e in endpoints
      if e == 'insights' && !missing
        continue
 
      for v in results[e]
        if !exists(v) and v.content.length > 0
          for c in v.content
            if c.image_url
              hasThumbnail = true
              v.image_url = c.image_url
            if v.description == '' and c.type == 'wiki'
              v.description = c.headline

            if c.image_url and v.description
              break

          if c.image_url and v.description
            output.push(v)

    return callback(null, output)
  )

slides = (request, reply) ->
  entities_threshold = 0.20
  keywords_threshold = 0.40

  if request.payload.entities_threshold
    entities_threshold = request.payload.entities_threshold

  if request.payload.keywords_threshold
    keywords_threshold = request.payload.keywords_threshold

  async.auto({
    concepts: (callback) ->
      concepts(request.payload.text, callback)
    entities: (callback) ->
      entities(request.payload.text, entities_threshold, callback)
    keywords: (callback) ->
      keywords(request.payload.text, keywords_threshold, callback)
    insights: (callback) ->
      insights(request.payload.text, callback)
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

entities = (text, threshold, next) ->
  options =
    maxRetrieve: 999999
    quotations: true

  alchemyapi.entities('text', text, options,
    (response) ->
      if response.status == 'ERROR'
        return next(null, [])

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

keywords = (text, threshold, next) ->
  options =
    keywordExtractMode: 'strict'

  alchemyapi.keywords('text', text, options,
    (response) ->
      if response.status == 'ERROR'
        return next(null, [])

      filter = (item, callback) ->
        if parseFloat(item.relevance) > threshold
          return callback(true)
        else
          return callback(false)

      async.filter(response['keywords'], filter, (results) ->
        next(null, results)
      )
    )

concepts = (text, next) ->
  alchemyapi.concepts('text', text, { maxRetrieve : 999999 },
    (response) ->
      if response.status == 'ERROR'
        return next(null, [])

      next(null, response['concepts'])
  )

insights = (text, next) ->
  payload =
    func: 'labelSearch'
    limit: 10
    prefix: true
    concepts: true
    query: text
    user: 'public'
    corpus: 'ibmresearcher'

  concept_insights.labelSearch(payload, (err, labels) ->
    if err
      console.err(err)
      return next(err)

    if !labels
      labels = []

    return next(null, labels)
  )


server.route(
  method: 'POST',
  path: '/slides',
  handler: (request, reply) ->
    slides(request, reply)
  config:
    payload:
      output: 'data'
)

server.start()
