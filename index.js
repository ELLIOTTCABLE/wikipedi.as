var URL          = require('url')
  , connect      = require('connect')
  , raven        = require('raven')
  , prettify     = new (require('pretty-error'))
  , Promise      = require('bluebird')
  , requestAsync = require('request-promise')

            Promise.longStackTraces() // “... a substantial performance penalty.” Okay.
var redis = Promise.promisifyAll(require('redis').createClient())
    redis.client('setname', "wikipedi.as")

// Populate the .sentry file if you wish to report exceptions to http://getsentry.com/ (=
try {
   var _sentry = JSON.parse(require('fs').readFileSync(__dirname + '/.sentry'))
      , sentry = new raven.Client('https://'+_sentry.public_key+':'+_sentry.secret_key+
                                  '@app.getsentry.com/'+_sentry.project_id)
      sentry.patchGlobal()
      process.on('uncaughtException', function(err){ console.error(prettify.render(err)) }) }
catch (e) { if (e.code !== 'ENOENT') throw e }


var PACKAGE   = JSON.parse(require('fs').readFileSync(__dirname + '/package.json'))
  , user_agent = PACKAGE.name+"/"+PACKAGE.version+" ("+PACKAGE.homepage+"; by "+PACKAGE.author+")"

function wikipedias(incoming, outgoing){
   var key = incoming.url.slice(1)
   
   requestAsync({
      uri: "http://en.wikipedia.org/w/api.php", json: true, encoding: 'utf8'
    , qs: {format: 'json', action: 'query', prop: 'info', titles: key}
   }).done(function(body){
      var pages   = body.query.pages
        , keys    = Object.keys(pages)
        , exists  = (pages[keys[0]].missing == null)
      
      if (exists) {
         outgoing.statusCode = 301
         outgoing.setHeader('Location', "http://en.wikipedia.org/wiki/" + key)
         return outgoing.end('Bye!') }
      
      else {
         outgoing.statusCode = 404
         return outgoing.end('Not found on Wikipedia.') }
      
   }) // requestAsync
}

// Determines if an article with the given title exists on Wikipedia. Returns a promise for the
// article's normalized title. Rejects if no such article exists.
function articleExists(title, language){
      return requestAsync({
         url: url({
            hostname: language.tag + '.wikipedia.org'
          , query: {
               action: 'query', prop: 'info'
             , titles: title
         }})
       , headers: { 'User-Agent': user_agent }
       , json: true
      }).then(function(resp){ resp = resp.query
         if (resp.pages[-1]) return undefined
         return resp.pages[Object.keys(resp.pages)[0]].title
      })
}

// Splits our disambiguation-category cache into manageable chunks, and queries Wikipedia as many
// times as necessary to determine if the article passed is in any of those categories.
// (Returns a promise.)
function isDisambiguation(title, language){
   return redis.smembersAsync('lang:'+language.tag+':cats')
   // ... split all the d-categories we know about into sets of 49 apiece, to appease the API limit
   //     of 50 at a time
   .reduce(function(sets, category){
      if (sets[sets.length-1].length >= 49) sets.push(new Array)
      var set = sets[sets.length-1]
      set.push(category)
      return sets
   }, [[]])
   // ... dispatch a request for each set of 49 categories, to see if the article belongs in any
   .map(function(set){
      return requestAsync({
         url: url({
            hostname: language.tag + '.wikipedia.org'
          , query: {
               action: 'query', prop: 'categories'
             , titles: title
             , clcategories: set.join('|')
             , cllimit: 'max'
         }})
       , headers: { 'User-Agent': user_agent }
       , json: true
       , transform: function(resp){ return resp.query.pages[Object.keys(resp.query.pages)[0]] }
      })
   }) // map sets
   .reduce(function(containing, page){
      console.log('page:', page)
      return containing.concat(page.categories || [])
   }, [])
   .then(function(categories){
      return categories.length !== 0
   })
}

// Generate a modify-able copy of the Wikipedia API URL
function url(u){
   u.protocol = 'http:'
   u.pathname = '/w/api.php'
   u.query.format = 'json'
   return URL.format(u)
}


var app = connect()
   .use( function(_, out, next){ out.setHeader('X-Awesome-Doggie', 'Tucker'); next() })
   .use( connect.favicon() )
   .use( connect.logger('tiny') )
   
   // We don't deign to handle index.html within the app. Let the user stick a reverse-proxy in
   // front of us, and let it do the static-file serving. This should never get reached.
   .use( function(incoming, outgoing, next){
      if (incoming.url !== '/') return next()
      throw new Error("There is no root!") })
   
   .use( wikipedias )
   
   .use( raven.middleware.connect(sentry) )
   .use( function(err, incoming, outgoing, next){
      outgoing.statusCode = 500
      outgoing.end('Server error: ' + err.message)
      throw err
   })

   .listen(1337)
