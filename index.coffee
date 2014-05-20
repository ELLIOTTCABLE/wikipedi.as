URL          = require 'url'
connect      = require 'connect'
raven        = require 'raven'
prettify     = new (require 'pretty-error')
Promise      = require 'bluebird'
requestAsync = require 'request-promise' 

redis = Promise.promisifyAll(require('redis').createClient())
redis.client('setname', "wikipedi.as")

Promise.longStackTraces() # “... a substantial performance penalty.” Okay.

# Populate the .sentry file if you wish to report exceptions to http://getsentry.com/ (=
try
   _sentry = JSON.parse require('fs').readFileSync __dirname + '/.sentry'
   sentry  = new raven.Client(
      "https://#{_sentry.public_key}:#{_sentry.secret_key}@app.getsentry.com/#{_sentry.project_id}")
   sentry.patchGlobal()
   process.on 'uncaughtException', (err)-> console.error prettify.render err
catch err then throw err if e.code != 'ENOENT'


PACKAGE    = JSON.parse require('fs').readFileSync __dirname + '/package.json'
user_agent = "#{PACKAGE.name}/#{PACKAGE.version} (#{PACKAGE.homepage}; by #{PACKAGE.author})"

wikipedias = (incoming, outgoing)->
   key = decodeURIComponent(incoming.url).slice 1
   
   redis.lrangeAsync 'langs', 0, -1
   .then (langs)->
      articleExistsIn key, langs
      
      # ... we now know where the article exists, and what its normalized name is.
      .then ({article, lang})->
         outgoing.statusCode = 301
         outgoing.setHeader 'Location', "http://#{lang}.wikipedia.org/wiki/#{article.title}"
         return outgoing.end 'Bye!'

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
      console.log 'page:', page
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


app = connect()
.use (_, out, next)-> out.setHeader 'X-Awesome-Doggie', 'Tucker'; next()
.use connect.favicon()
.use connect.logger 'tiny'

# We don't deign to handle index.html within the app. Let the user stick a reverse-proxy in
# front of us, and let it do the static-file serving. This should never get reached.
.use (incoming, outgoing, next)->
   return next() if incoming.url != '/'
   throw new Error "There is no root!"

.use wikipedias

.use raven.middleware.connect sentry
.use (err, incoming, outgoing, next)->
   outgoing.statusCode = 500
   outgoing.end 'Server error: ' + err.message
   throw err

.listen 1337
