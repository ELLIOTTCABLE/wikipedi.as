debug        = require('debug') 'wikipedias:http'
URL          = require 'url'
connect      = require 'connect'
st           = require 'st'
mustache     = require 'mustache'
marked       = require 'marked'
prettify     = new (require 'pretty-error')
Promise      = require 'bluebird'
requestAsync = require 'request-promise'

newrelic     = undefined
raven        = undefined

if process.env['NEW_RELIC_ENABLED'] == 'true'
   try
      newrelic = require 'newrelic'
      debug 'New Relic connected'
   catch err then throw err if err.code != 'MODULE_NOT_FOUND'

redis = Promise.promisifyAll require('redis').createClient process.env['REDIS_URL']
redis.auth auth if auth = process.env['REDIS_AUTH'] # Should probably wrap the rest in the callback

redis.client 'setname', 'wikipedias', (err)->
   # swallow errors
debug 'Redis connected to `%s`', redis.address

prettify.skipNodeFiles()
Promise.longStackTraces() # “... a substantial performance penalty.” Okay.

PACKAGE    = JSON.parse require('fs').readFileSync __dirname + '/package.json'
languages  = JSON.parse(require('fs').readFileSync __dirname + '/languages.json').languages

# Populate SENTRY_DSN if you wish to report exceptions to http://getsentry.com/ (=
if process.env['SENTRY_DSN']
   try
      raven = require 'raven'

      sentry  = new raven.Client process.env['SENTRY_DSN'],
         release: PACKAGE.version

      sentry.patchGlobal()
      process.on 'uncaughtException',      (err)-> console.error prettify.render err
      Promise.onPossiblyUnhandledRejection (err)->
         sentry.captureError err
         console.error prettify.render err

      debug 'Sentry connected'
   catch err then throw err if err.code != 'MODULE_NOT_FOUND'

port = parseInt(process.env['PORT']) || 1337


user_agent = "#{PACKAGE.name}/#{PACKAGE.version} (#{PACKAGE.homepage}; by #{PACKAGE.author})"
templates  = require('glob').sync("Resources/*.mustache").reduce ((templates, filename)->
   name = require('path').basename filename, '.mustache'
   source = require('fs').readFileSync filename, encoding: 'utf8'
   mustache.parse source
   templates[name] = source
   templates
), {}
debug 'Templates loaded'

wikipedias = (incoming, outgoing)->
   url = URL.parse incoming.url, true
   key = url.pathname.slice 1
   key = url.query.key unless key.length
   key = decodeURIComponent key
   debug "Key requested: '%s'", key

   # If we have previously resolved this key, respond with that.
   redis.getAsync "article:#{key}:url"
   .then (resolved)-> if resolved?
      debug "'%s' already cached as %s", key, resolved
      outgoing.statusCode = 301
      outgoing.setHeader 'Location', resolved
      return outgoing.end 'Bye!'

   else
      debug "'%s' isn't cached,", key
      articleExistsIn key, languages

      # ... we now know where the article exists, and what its normalized name is.
      .then ({article, language})->
         isDisambiguation(article.title, language).then (isDisambiguation)->
            unless isDisambiguation
               resolved = "http://#{language.ISO639}.wikipedia.org/wiki/#{article.title}"
               return redis.setAsync "article:#{key}:url", resolved
               .then -> redis.saddAsync "articles", key
               .then ->
                  debug "'%s' cached to DB: ", key, resolved
                  outgoing.statusCode = 301
                  outgoing.setHeader 'Location', resolved
                  return outgoing.end 'Bye!'

            # Temporarily ... at least, until I can write the code to properly handle them ...
            resolved = "http://#{language.ISO639}.wikipedia.org/wiki/#{article.title}"
            debug "'%s' is disambiguation, not cached to DB: ", key, resolved
            outgoing.statusCode = 302
            outgoing.setHeader 'Location', resolved
            return outgoing.end """
               That's a disambiguation page.
               This isn't implemented yet, so I'll just redirect you.
            """

      # ... If we can't find any article by this title on *any* Wikipedia,
      .catch ReferenceError, (err)->
         debug "'%s' doesn't exist on any of our Wikipedias", key
         outgoing.statusCode = 404
         outgoing.end err.message


# Determine if an article exists on *any* Wikipedia (within `langs`). Returns a promise for an
# `{ title: <normalized title>, language: language-info-object }`. If no language matches the title
# in question, the promise is rejected.
articleExistsIn = (title, languages)->
   scan = languages.reduceRight ((skip, language)->->
      articleExists(title, language)
      .then (article)->
         debug "'%s' found in %s: %j", title, language.name, article
         return { article: article, language: language }
      .error skip

   ), -> Promise.reject new ReferenceError "'#{title}' could not be found on any Wikipedia"

   scan()

# Determines if an article with the given title exists on Wikipedia. Returns a promise for the
# article's Wikipedia info. Rejects if no such article exists.
articleExists = (title, language)->
      requestAsync
         url: url
            hostname: "#{language.ISO639}.wikipedia.org"
            query:
               action: 'query', prop: 'info'
               titles: title
         headers: { 'User-Agent': user_agent }
         json: true
      .then ({query})->
         page = query.pages[Object.keys(query.pages)[0]]
         if page.missing?
            debug "'%s' doesn't exist in %s.", title, language.name
            return Promise.reject new ReferenceError(
               "'#{page.title}' was not found in '#{language.name}'")
         return page

# Checks if a Wikimedia-properties page is marked as a __DISAMBIG__. (Thanks,
# https://www.mediawiki.org/wiki/Extension:Disambiguator!)
#
# Returns a promise.
isDisambiguation = (title, language)->
  requestAsync
      url: url
         hostname: "#{language.ISO639}.wikipedia.org"
         query:
            action: 'query', prop: 'pageprops'
            ppprop: 'disambiguation'
            titles: title
      headers: { 'User-Agent': user_agent }
      json: true

   # Important note: if the page is a disambiguation page, the API will return an *empty string* as
   # the value of pageprops.disambiguation. (No, this makes no sense.) Hence the *existence test*
   # below, instead of a truthiness test.
   .then ({query})->
      page = query.pages[Object.keys(query.pages)[0]]
      return page.pageprops?.disambiguation?

# Generate a modify-able copy of the Wikipedia API URL
url = (u)->
   u.protocol = 'http:'
   u.pathname = '/w/api.php'
   u.query.format = 'json'
   URL.format u


# --- ---- --- /!\ --- ---- --- #

nest_template = (template)-> -> (content, outer_render)->
   view = Object.create this
   view.yield = -> outer_render content
   mustache.render template, view, templates

register_footnote = (content)->
   content = new String(content)
   content.index = => @footnotes.indexOf(content) + 1
   (@footnotes ||= new Array).push content
   null

app = connect()
.use (_, o, next)->
   o.setHeader 'X-Awesome-Doggie', 'Tucker'
   o.setHeader 'X-UA-Compatible', 'IE=edge'
   next()

.use connect.favicon('Resources/favicon.ico')

# TODO: I should probably cache this.
.use (i, o, next)->
   return next() unless i.url == '/'

   redis.scardAsync('articles')
   .then (count)->
      view =
         count: count
         markdown: -> (content, r)-> marked r content
         framework: nest_template templates.framework

         fn: -> (number)->
            "<sup id='ref#{number}' class='fnref'><a href='#fn#{number}'>(#{number})</a></sup>"

         footnote: -> (content, r)-> register_footnote.call this, marked r content

      o.setHeader 'Content-Type', 'text/html'
      o.end mustache.render templates.landing, view, templates

.use st
   path: 'Resources/'
   index: false
   passthrough: true

.use st
   path: 'bower_components/'
   index: false
   passthrough: true

.use st
   path: 'bower_components/html5-boilerplate/'
   index: false
   passthrough: true

.use connect.logger 'tiny'
.use wikipedias

app.use raven.middleware.connect sentry if raven
app.use (err, _, o, next)->
   o.statusCode = 500
   o.end 'Server error: ' + err.message
   throw err

debug 'Listening on: %d', port
app.listen port
