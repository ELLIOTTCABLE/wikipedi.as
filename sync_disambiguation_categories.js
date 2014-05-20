var URL          = require('url')
  , raven        = require('raven')
  , Promise      = require('bluebird')
  , requestAsync = require('request-promise')

            Promise.longStackTraces() // “... a substantial performance penalty.” Okay.
var redis = Promise.promisifyAll(require('redis').createClient())
    redis.client('setname', "wikipedi.as:disambiguation-sync")

// Populate the .sentry file if you wish to report exceptions to http://getsentry.com/ (=
//try {
//   var _sentry = JSON.parse(require('fs').readFileSync(__dirname + '/.sentry'))
//      , sentry = new raven.Client('https://'+_sentry.public_key+':'+_sentry.secret_key+
//                                  '@app.getsentry.com/'+_sentry.project_id)
//      sentry.patchGlobal()
//      process.on('uncaughtException', function(err){ console.log(err.stack); process.exit(1) })
//   }
//catch (e) { if (e.code !== 'ENOENT') throw e }


// var languages = JSON.parse(require('fs').readFileSync(__dirname + '/languages.json')).languages
var languages = [
   { "name": "English",    "tag": "en", "cats": ["Category:Disambiguation pages", "Category:All disambiguation pages"] }
]

  , seen = []

transaction = redis.multi()

Promise.all(languages.map(function(language){
   transaction.set('lang:'+language.tag+':name', language.name)
   transaction.del('lang:'+language.tag+':cats')
   return Promise.all(language.cats.map(function(cat){
      return pushSubCategories(cat, language) }))
}))
.then(function(){
   return Promise.promisify(transaction.exec, transaction)()
})
.done(function(){
   console.log('-- All done!')
   return redis.quitAsync() })


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
    , json: true
    , transform: function(resp){ return resp.query.categorymembers }
   })
   
   .map(function(member){
      // Do I need to do something with member.pageid, here? Not sure if I need it for further
      // API calls into the MediaWiki system.
      if (depth < 3)
         return pushSubCategories(member.title, language, depth+1)
   })
}
