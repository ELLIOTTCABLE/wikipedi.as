var connect      = require('connect')
  , raven        = require('raven')
  , Promise      = require('bluebird')
  , requestAsync = require('request-promise')

Promise.longStackTraces() // “... a substantial performance penalty.” Okay.

// Populate the .sentry file if you wish to report exceptions to http://getsentry.com/ (=
try {
   var _sentry = JSON.parse(require('fs').readFileSync(__dirname + '/.sentry'))
      , sentry = new raven.Client('https://'+_sentry.public_key+':'+_sentry.secret_key+
                                  '@app.getsentry.com/'+_sentry.project_id)
        sentry.patchGlobal() }
catch (e) { if (e.code !== 'ENOENT') throw e }


var primaryHandler = function(incoming, outgoing){
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


var app = connect()
   .use( function(_, out, next){ out.setHeader('X-Awesome-Doggie', 'Tucker'); next() })
   .use( connect.favicon() )
   .use( connect.logger('tiny') )
   
   .use( function(incoming, outgoing, next){
      if (incoming.url !== '/') return next()
      throw new Error("There is no root!") })
   
   .use( primaryHandler )
   
   .use( raven.middleware.connect(sentry) )
   .use( function(err, incoming, outgoing, next){
      outgoing.statusCode = 500
      outgoing.end('Server error: ' + err.message)
      throw err
   })

   .listen(1337)
