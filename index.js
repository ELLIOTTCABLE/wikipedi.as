var connect      = require('connect')
  , raven        = require('raven')
  , Promise      = require('bluebird')
  , requestAsync = require('request-promise')

Promise.longStackTraces() // “... a substantial performance penalty.” Okay.

var _sentry = JSON.parse(require('fs').readFileSync(__dirname + '/.sentry'))
   , sentry = new raven.Client('https://'+_sentry.public_key+':'+_sentry.secret_key+
                               '@app.getsentry.com/'+_sentry.project_id)
     sentry.patchGlobal()


var app = connect()
   .use( connect.favicon() )
   .use( function(incoming, outgoing, next){
      if (incoming.url !== '/') return next()
      throw new Error("There is no root!") })
   
   .use( connect.logger('tiny') )
   
   .use( function(incoming, outgoing){
      outgoing.setHeader('X-Awesome-Doggie', 'Tucker')
      
      var title = incoming.url.slice(1)
      
      requestAsync({
         uri: "http://en.wikipedia.org/w/api.php", json: true, encoding: 'utf8'
       , qs: {format: 'json', action: 'query', prop: 'info', titles: title}
      }).done(function(body){
         var pages   = body.query.pages
           , keys    = Object.keys(pages)
           , exists  = (pages[keys[0]].missing == null)
         
         if (exists) {
            outgoing.statusCode = 301
            outgoing.setHeader('Location', "http://en.wikipedia.org/wiki/" + title)
            return outgoing.end('Bye!') }
         
         else {
            outgoing.statusCode = 404
            return outgoing.end('Not found on Wikipedia.') }
         
      }) // requestAsync
   }) // .use function(incoming, outgoing)
   
   .use( raven.middleware.connect(sentry) )
   .use( function(err, incoming, outgoing, next){
      outgoing.statusCode = 500
      outgoing.end('Server error: ' + err.message)
      throw err
   })


require('http').createServer(app).listen(1337)
