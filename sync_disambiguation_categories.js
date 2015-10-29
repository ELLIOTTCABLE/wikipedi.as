var URL          = require('url')
  , Promise      = require('bluebird')
  , requestAsync = require('request-promise')

            Promise.longStackTraces() // “... a substantial performance penalty.” Okay.
var redis = Promise.promisifyAll(require('redis').createClient(undefined, process.env['REDIS_HOST']))
  , auth = process.env['REDIS_AUTH']
    if (auth) redis.auth(auth)
    redis.client('setname', "wikipedi.as:disambiguation-sync", function(err){
      /* Swallow errors. */ })

// Populate SENTRY_DSN if you wish to report exceptions to http://getsentry.com/ (=
if (process.env['SENTRY_DSN']) try {
   var raven = require('raven')
     , sentry = new raven.Client(process.env['SENTRY_DSN'])

   sentry.patchGlobal()
   process.on('uncaughtException', function(err){
      console.error(err)
      process.exit(1) })
   Promise.onPossiblyUnhandledRejection(function(err){
      sentry.captureError(err)
      console.error(err)
      process.exit(1) })

} catch (e) { if (e.code !== 'MODULE_NOT_FOUND') throw e }

var languages = JSON.parse(require('fs').readFileSync(__dirname + '/languages.json')).languages
  , PACKAGE   = JSON.parse(require('fs').readFileSync(__dirname + '/package.json'))
  , seen      = new Array
  , user_agent =
   PACKAGE.name+"/"+PACKAGE.version
      +" ("+PACKAGE.homepage+"; by "+PACKAGE.author+") DisambiguationCrawler"

console.log('-- User-Agent:', require('util').inspect(user_agent))
transaction = redis.multi()
transaction.del('langs')

Promise.all(languages.map(function(language){
   transaction.rpush('langs', language.tag)
   transaction.set('lang:'+language.tag+':name', language.name)
   transaction.del('lang:'+language.tag+':cats')
   return Promise.all(language.cats.map(function(cat){
      return pushSubCategories(cat, language) }))
}))
.then(function(){
   return Promise.promisify(transaction.exec, transaction)()
})
.done(function(){
   Promise.all(languages.map(function(language){
      return redis.scardAsync('lang:'+language.tag+':cats') }))
   .then(function(counts){
      console.log('-- All done!')
      languages.forEach(function(language, idx){
         console.log(language.name+': '+counts[idx]) })
      return redis.quitAsync()
}) })


function pushSubCategories(category, language, depth){ if (typeof depth != 'number') depth = 1
   if (seen.indexOf(category) !== -1) return;

   transaction.sadd('lang:'+language.tag+':cats', category)
   seen.push(category)
   console.log(language.tag+' '+depth+':', category)

   return requestAsync({
      url: URL.format({
         protocol: 'http:'
       , hostname: language.tag + '.wikipedia.org'
       , pathname: '/w/api.php'
       , query: {
            format: 'json'
          , action: 'query'
          , list: 'categorymembers'
          , cmtitle: category
          , cmtype: 'subcat'
          , cmlimit: 'max'
      }})
    , headers: { 'User-Agent': user_agent }
    , json: true
    , transform: function(resp){ return resp.query.categorymembers }
   })

   .map(function(member){
      // Do I need to do something with member.pageid, here? Not sure if I need it for further
      // API calls into the MediaWiki system.
      if (depth < 4)
         return Promise.delay(1000).then(function(){
            return pushSubCategories(member.title, language, depth+1) })
   })
}
