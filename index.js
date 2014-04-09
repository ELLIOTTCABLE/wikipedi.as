http        = require('http')
http.client = require('request')
url         = require('url')

server = http.createServer()

server.on('request', function(request, response){
   var title = request.url.slice(1)
   
   response.setHeader('X-Awesome-Doggie', 'Tucker')
   
   http.client.get({
      uri: "http://en.wikipedia.org/w/api.php", json: true, encoding: 'utf8'
    , qs: {format: 'json', action: 'query', titles: title}
   }, function(err, _, body){
      var pages   = body.query.pages
        , keys    = Object.keys(pages)
        , exists  = (pages[keys[0]].missing == null)
      if (exists) {
         response.statusCode = 301
         response.setHeader('Location', "http://en.wikipedia.org/wiki/" + title)
         
         response.end('Bye!')
      }
      else {
         response.statusCode = 404
         response.end('Not found on Wikipedia.')
      }
      
      console.log(title + ': ' + (exists? 'Extant.' : 'Missing!'))
   })
   
}) // server.on 'request'


server.listen(1337)
