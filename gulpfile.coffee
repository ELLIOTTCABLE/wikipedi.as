gulp = require 'gulp'   # Why must I do this? C'mmon, gulp.
util = require 'gulp-util'
lazy = require 'lazypipe'
plugin = (name)-> require "gulp-#{name}"


paths =
   resources: lazy().pipe gulp.dest, './Resources'

   css: [ './Resources/main.less' ]
   js:
      synch: [    # <head>-loaded (start)
         './bower_components/typekit-load/load.min.js'
         './Resources/Vendor/modernizr.min.js' ]
      asynch: [   # <body>-loaded (end)
         './Resources/main.coffee' ]


gulp.task 'default', ['build']
gulp.task 'all',     ['build']
gulp.task 'build', ['build-css', 'build-js']
gulp.task 'watch', ['watch-css', 'watch-js']


gulp.task 'build-css', ['clean-css'], ->
   return gulp
      .src paths.css
      .pipe plugin('if') /[.]less$/, plugin('less') paths: './Resources'
      .pipe plugin('myth')()
      .pipe plugin('minify-css') keepBreaks: yes
      .pipe paths.resources()

gulp.task 'watch-css', (done)->
   plugin('watch') glob: paths.css, (_)->
      _  .pipe plugin('debug') title: 'css'
         .pipe plugin('if') /[.]less$/, handle plugin('less') paths: './Resources'
         .pipe handle plugin('myth')()
#        .pipe plugin('concat') 'main.css'
         .pipe handle plugin('minify-css') keepBreaks: yes
         .pipe paths.resources()

gulp.task 'clean-css', ->
   return gulp
      .src './Resources/*.css', read: no
      .pipe plugin('rimraf')()


js     = lazy().pipe(plugin 'uglify').pipe(paths.resources)

gulp.task 'build-js', ['clean-js'], ->
   synch = gulp
      .src paths.js.synch
      .pipe plugin('if') /[.]coffee$/, plugin('coffee') bare: yes, header: no
      .pipe plugin('concat') 'synch.concat.js'
      .pipe js()

   asynch = gulp
      .src paths.js.asynch
      .pipe plugin('if') /[.]coffee$/, plugin('coffee') bare: yes, header: no
      .pipe plugin('concat') 'asynch.concat.js'
      .pipe js()

   return require('stream-combiner') synch, asynch

gulp.task 'watch-js', (done)->
   plugin('watch') glob: paths.js.synch, (_)->
      _  .pipe plugin('debug') title: 'synch'
         .pipe plugin('if') /[.]coffee$/, handle plugin('coffee') bare: yes, header: no
         .pipe plugin('concat') 'synch.concat.js'
         .pipe js()

   plugin('watch') glob: paths.js.asynch, (_)->
      _  .pipe plugin('debug') title: 'asynch'
         .pipe plugin('if') /[.]coffee$/, handle plugin('coffee') bare: yes, header: no
         .pipe plugin('concat') 'asynch.concat.js'
         .pipe js()

gulp.task 'clean-js', ->
   return gulp
      .src './Resources/*.js', read: no
      .pipe plugin('rimraf')()

handle = (stream)->
   stream.on 'error', ->
      util.log.apply this, arguments
      stream.end()
   return stream
