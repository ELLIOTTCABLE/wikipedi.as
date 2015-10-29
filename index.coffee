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
   try newrelic = require 'newrelic'
   catch err then throw err if err.code != 'MODULE_NOT_FOUND'

redis = Promise.promisifyAll require('redis').createClient process.env['REDIS_URL']
redis.auth auth if auth = process.env['REDIS_AUTH'] # Should probably wrap the rest in the callback

redis.client 'setname', 'wikipedias', (err)->
   # swallow errors

prettify.skipNodeFiles()
Promise.longStackTraces() # “... a substantial performance penalty.” Okay.

PACKAGE    = JSON.parse require('fs').readFileSync __dirname + '/package.json'

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
   catch err then throw err if err.code != 'MODULE_NOT_FOUND'


user_agent = "#{PACKAGE.name}/#{PACKAGE.version} (#{PACKAGE.homepage}; by #{PACKAGE.author})"
templates  = require('glob').sync("Resources/*.mustache").reduce ((templates, filename)->
   name = require('path').basename filename, '.mustache'
   source = require('fs').readFileSync filename, encoding: 'utf8'
   mustache.parse source
   templates[name] = source
   templates
), {}

wikipedias = (incoming, outgoing)->
   url = URL.parse incoming.url, true
   key = url.pathname.slice 1
   key = url.query.key unless key.length
   key = decodeURIComponent key

   # If we have previously resolved this key, respond with that.
   redis.getAsync "article:#{key}:url"
   .then (resolved)-> if resolved?
      outgoing.statusCode = 301
      outgoing.setHeader 'Location', resolved
      return outgoing.end 'Bye!'

   else
      redis.lrangeAsync 'langs', 0, -1
      .then (langs)->
         articleExistsIn key, langs

         # ... we now know where the article exists, and what its normalized name is.
         .then ({article, lang})->
            isDisambiguation(article.title, lang).then (isDisambiguation)->
               unless isDisambiguation
                  resolved = "http://#{lang}.wikipedia.org/wiki/#{article.title}"
                  return redis.setAsync "article:#{key}:url", resolved
                  .then -> redis.saddAsync "articles", key
                  .then ->
                     outgoing.statusCode = 301
                     outgoing.setHeader 'Location', resolved
                     return outgoing.end 'Bye!'

               # Temporarily ... at least, until I can write the code to properly handle them ...
               resolved = "http://#{lang}.wikipedia.org/wiki/#{article.title}"
               outgoing.statusCode = 302
               outgoing.setHeader 'Location', resolved
               return outgoing.end """
                  That's a disambiguation page.
                  This isn't implemented yet, so I'll just redirect you.
               """

         # ... If we can't find any article by this title on *any* Wikipedia,
         .error (err)->
            outgoing.statusCode = 404
            outgoing.end err.message


# Determine if an article exists on *any* Wikipedia (within `langs`). Returns a promise for an
# `{ title: <normalized title>, lang: <language code> }`. If no language matches the title in
# question, the promise is rejected.
articleExistsIn = (title, langs)->
   scan = langs.reduceRight ((skip, lang)->->
      articleExists(title, lang)
      .then (article)-> { article: article, lang: lang }
      .error skip

   ), -> Promise.reject new ReferenceError "'#{title}' could not be found on any Wikipedia"

   scan()

# Determines if an article with the given title exists on Wikipedia. Returns a promise for the
# article's Wikipedia info. Rejects if no such article exists.
articleExists = (title, lang)->
      requestAsync
         url: url
            hostname: "#{lang}.wikipedia.org"
            query:
               action: 'query', prop: 'info'
               titles: title
         headers: { 'User-Agent': user_agent }
         json: true
      .then ({query})->
         page = query.pages[Object.keys(query.pages)[0]]
         if page.missing?
            return Promise.reject new ReferenceError "'#{page.title}' was not found"
         return page

# Splits our disambiguation-category cache into manageable chunks, and queries Wikipedia as many
# times as necessary to determine if the article passed is in any of those categories.
# (Returns a promise.)
isDisambiguation = (title, lang)->
   redis.smembersAsync "lang:#{lang}:cats"
   # ... split all the d-categories we know about into sets of 49 apiece, to appease the API limit
   #     of 50 at a time
   .reduce( (sets, category)->
      sets.push new Array if sets[sets.length-1].length >= 49
      set = sets[sets.length-1]
      set.push category
      sets
   , [[]] )

   # ... dispatch a request for each set of 49 categories, to see if the article belongs in any
   .map (set)->
      requestAsync
         url: url
            hostname: lang + '.wikipedia.org'
            query:
               action: 'query', prop: 'categories'
               titles: title
               clcategories: set.join '|'
               cllimit: 'max'
         headers: { 'User-Agent': user_agent }
         json: true
         transform: (resp)-> resp.query.pages[Object.keys(resp.query.pages)[0]]

   .reduce( (containing, page)->
      containing.concat page.categories || []
   , [] )
   .then (categories)->
      categories.length != 0

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

app.listen 1337
