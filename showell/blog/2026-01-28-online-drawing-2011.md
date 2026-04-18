## Online Drawing (2011)

*January 28, 2026*

Back in 2011 I created a little logo-like tool to teach folks
how to use the canvas.  It used CoffeeScript as its language.
I think it's a pretty good language for that particular task.

Here is a screenshot from the app or you can
[just run the app here](http://showell.github.io/OnlineDrawing/demo.htm):

![OnlineDrawing](smiley.webp)

You can explore the code at [my OnlineDrawing repo](https://github.com/showell/OnlineDrawing)

The program was able to run 14 years later. I just had to update
jQuery so that modern browsers like Brave would run it.

~~~ diff
-    <script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jquery/1.6.1/jquery.min.js"></script>
+    <script src="https://code.jquery.com/jquery-4.0.0.min.js"
+                   integrity="sha256-OaVG6prZf4v69dPg6PhVattBXkcOWQB62pdZ3ORyrao="
+                   crossorigin="anonymous">
+    </script>
~~~

There are some fun technical details in the program.  For example, I actually run
the CoffeeScript compiler in the browser:

~~~ coffeescript
run_code = (code) ->
  try
    js = CoffeeScript.compile CHALLENGE.prelude + code
  catch e
    console.log e
    console.log "(problem with compiling CS)"
  eval js
~~~

Here is a typical challenge called "Launch the Ball":

~~~ coffeescript
  {
    title: "Launch the Ball"

    prelude: '''
      env = window.helpers()
      {circle, launch} = env
      ''' + '\n'

    code: '''
      # Challenge: Change the angle so that you launch the ball clear over the wall.
      # Just use trial and error to find the correct steepness.
      ball = circle()
      angle = 35
      launch ball, angle
      '''
  },
~~~

Here's the launch helper:

~~~ coffeescript
  launch = (ball, angle) ->
    wall_offset = 315
    wall_height = 427
    ball_radius = 15
    line [wall_offset, 0], [wall_offset, wall_height]
    line [wall_offset - ball_radius, wall_height], [wall_offset, wall_height]

    cx = 0
    cy = 0
    ball.goto(0, 0)
    v = 7
    dx = v * cosine(angle)
    dy = v * sine(angle)
    over_wall = false
    flying = true
    repeat ->
      return if !flying

      flying = false if cy < 0 or cx > width

      if flying and !over_wall and cx + ball_radius >= wall_offset
        if cy > wall_height + ball_radius
          if cx >= wall_offset
            over_wall = true
        else
          flying = false

      if flying
        cx += dx
        cy += dy
        ball.goto(cx, cy)
        dy -= 0.05
~~~


I used a home-grown HAML-like system to buid out my HTML. I called
it PipeDent.

~~~ coffeescript
demo_layout = \
  '''
  table
    tr valign="top"
      td id ="sideBar"
        ul id="program_list" |
      td id="leftPanel"
        h2 id="leftPanel" | Input
        input type="submit" value="Run" id="runCode" |
        <br>
        textarea id="input_code" rows=30 cols=80 |
      td id="rightPanel"
        h4 | Output
        div id="main" |
  '''
~~~
