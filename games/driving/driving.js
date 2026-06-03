(function () {
  'use strict';

  // ---- canvas ----
  var canvas = document.getElementById('c');
  var ctx = canvas.getContext('2d');
  var W = canvas.width;
  var H = canvas.height;
  var fpsEl = document.getElementById('fps');

  // ---- camera / projection ----
  // World axes: +x = east, +y = up, +z = north. 1 unit = 1 meter.
  // Heading: 0 = facing +z. Positive heading turns clockwise from above
  // (player's right). So forward direction is (sin h, 0, cos h).
  var FOV = 70;
  var focal = (W / 2) / Math.tan((FOV / 2) * Math.PI / 180);
  var nearPlane = 0.3;
  var cameraHeight = 1.2;  // driver eye level (m)

  // ---- world / map (encoded in JS) ----
  // Scene: a parking lot with two facing rows; player is mid-row, facing
  // out (north). Driveway gap at the WEST end (x < -10) connects to a
  // street running east-west, with 2-story apartments across.
  function car(x, z, color) {
    return { kind: 'car', x: x, z: z, w: 1.8, h: 1.45, d: 4.5, color: color };
  }

  var world = {
    // Flat ground quads. Drawn in list order before any 3D box. Non-overlapping
    // areas at the same y=0 plane don't need depth sort; for overlapping
    // (grass under everything) just list the underlying surface first.
    ground: [
      { x1: -300, z1: -80, x2: 300, z2: 120, color: '#2f7a30' },  // grass everywhere
      { x1:  -25, z1: -12, x2:  16, z2:   8, color: '#3a3a40' },  // parking lot
      { x1:  -20, z1:   8, x2: -10, z2:  12, color: '#3a3a40' },  // exit driveway
      { x1: -300, z1:  12, x2: 300, z2:  22, color: '#2c2c30' },  // street
      { x1: -300, z1:  22, x2: 300, z2:  24, color: '#a0a0a8' },  // far sidewalk
    ],
    lines: [],  // populated below
    obstacles: [
      // player's row (player at x=0, z=-5.5; cars to either side)
      car(-10,   -5.5, '#9b2c2c'),
      car( -7.5, -5.5, '#2e4d8a'),
      car( -5,   -5.5, '#7a6730'),
      car( -2.5, -5.5, '#2d5060'),
      car(  2.5, -5.5, '#88307a'),
      car(  5,   -5.5, '#327832'),
      car(  7.5, -5.5, '#5c3c3c'),
      car( 10,   -5.5, '#787880'),
      car( 13,   -5.5, '#3a1ea0'),
      // opposite row, facing south (boxes are symmetric, heading is for the
      // player's orientation memory only)
      car(-10,    5.5, '#a08020'),
      car( -7.5,  5.5, '#107050'),
      car( -5,    5.5, '#503070'),
      car( -2.5,  5.5, '#403028'),
      car(  0,    5.5, '#9c4060'),
      car(  2.5,  5.5, '#208058'),
      car(  5,    5.5, '#7a5430'),
      car(  7.5,  5.5, '#205080'),
      car( 10,    5.5, '#a04040'),
      car( 13,    5.5, '#808040'),
      // 2-story apartments across the street
      { kind: 'building', x: -25, z: 30, w: 18, h: 6.5, d: 9, color: '#c8a878', roof: '#5a3a2a' },
      { kind: 'building', x:   0, z: 30, w: 18, h: 6.5, d: 9, color: '#aa9468', roof: '#4a3328' },
      { kind: 'building', x:  25, z: 30, w: 18, h: 6.5, d: 9, color: '#b89876', roof: '#5a3a2a' },
    ],
  };

  // generate parking-spot stripes + street markings
  (function () {
    var x;
    for (x = -11.25; x <= 14.3; x += 2.5) {
      world.lines.push({ x1: x - 0.06, z1: -8.5, x2: x + 0.06, z2: -2.5, color: '#dadada' });
      world.lines.push({ x1: x - 0.06, z1:  2.5, x2: x + 0.06, z2:  8.5, color: '#dadada' });
    }
    // dashed yellow centerline on the street
    for (x = -200; x < 200; x += 6) {
      world.lines.push({ x1: x, z1: 16.85, x2: x + 3, z2: 17.15, color: '#e8c840' });
    }
    // white edge lines on the street
    world.lines.push({ x1: -300, z1: 12.15, x2: 300, z2: 12.30, color: '#dadada' });
    world.lines.push({ x1: -300, z1: 21.70, x2: 300, z2: 21.85, color: '#dadada' });
  })();

  // ---- player ----
  var player = { x: 0, z: -5.5, heading: 0, speed: 0 };
  var maxSpeed = 22;       // m/s (~50 mph)
  var reverseLimit = -6;   // m/s
  var accel = 8;
  var brake = 14;
  var handBrakeDecel = 24;
  // No coast friction — only braking / off-pavement slows you.

  // ---- input ----
  var keys = {};
  window.addEventListener('keydown', function (e) {
    keys[e.code] = true;
    if (e.code === 'ArrowUp' || e.code === 'ArrowDown' ||
        e.code === 'ArrowLeft' || e.code === 'ArrowRight' ||
        e.code === 'Space') e.preventDefault();
  });
  window.addEventListener('keyup', function (e) { keys[e.code] = false; });

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  // ---- update ----
  function update(dt) {
    if (keys.ArrowUp)   player.speed += accel * dt;
    if (keys.ArrowDown) player.speed -= brake * dt;
    if (keys.Space) {
      if (player.speed > 0) player.speed = Math.max(0, player.speed - handBrakeDecel * dt);
      else                  player.speed = Math.min(0, player.speed + handBrakeDecel * dt);
    }
    player.speed = clamp(player.speed, reverseLimit, maxSpeed);

    // Steering rate ramps in with speed so you can't pivot in place.
    var absSpeed = Math.abs(player.speed);
    var steerRate = 1.7 * Math.min(1, absSpeed / 3);
    var steerInput = (keys.ArrowLeft ? -1 : 0) + (keys.ArrowRight ? 1 : 0);
    if (player.speed < 0) steerInput = -steerInput;  // reverse inverts
    player.heading += steerInput * steerRate * dt;

    var dx = Math.sin(player.heading) * player.speed * dt;
    var dz = Math.cos(player.heading) * player.speed * dt;
    if (!collides(player.x + dx, player.z + dz)) {
      player.x += dx;
      player.z += dz;
    } else if (!collides(player.x + dx, player.z)) {
      player.x += dx;
      player.speed *= 0.4;
    } else if (!collides(player.x, player.z + dz)) {
      player.z += dz;
      player.speed *= 0.4;
    } else {
      player.speed *= 0.05;
    }
  }

  function collides(x, z) {
    var pad = 0.7;  // approximate player half-width / front-rear clearance
    for (var i = 0; i < world.obstacles.length; i++) {
      var o = world.obstacles[i];
      var hw = o.w / 2 + pad;
      var hd = o.d / 2 + pad;
      if (x > o.x - hw && x < o.x + hw && z > o.z - hd && z < o.z + hd) return true;
    }
    return false;
  }

  // ---- camera-space transform, near-plane clip, project ----
  function toCam(wx, wy, wz) {
    var dx = wx - player.x;
    var dy = wy - cameraHeight;
    var dz = wz - player.z;
    var ch = Math.cos(player.heading);
    var sh = Math.sin(player.heading);
    return {
      x: ch * dx - sh * dz,
      y: dy,
      z: sh * dx + ch * dz,
    };
  }

  // Sutherland-Hodgman clip of a convex polygon against z >= nearPlane in
  // camera space. Without this, ground quads and adjacent-car side faces
  // pop out as you drive past their rear corners.
  function clipNear(verts) {
    var out = [];
    var n = verts.length;
    for (var i = 0; i < n; i++) {
      var a = verts[i];
      var b = verts[(i + 1) % n];
      var aIn = a.z >= nearPlane;
      var bIn = b.z >= nearPlane;
      if (aIn) out.push(a);
      if (aIn !== bIn) {
        var t = (nearPlane - a.z) / (b.z - a.z);
        out.push({
          x: a.x + t * (b.x - a.x),
          y: a.y + t * (b.y - a.y),
          z: nearPlane,
        });
      }
    }
    return out;
  }

  function project(p) {
    return {
      x: W / 2 + (p.x / p.z) * focal,
      y: H / 2 - (p.y / p.z) * focal,
    };
  }

  function fillPolygon(pts, color) {
    if (pts.length < 3) return;
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
    ctx.closePath();
    ctx.fill();
  }

  function drawWorldPolygon(worldVerts, color) {
    var cam = [];
    for (var i = 0; i < worldVerts.length; i++) {
      var w = worldVerts[i];
      cam.push(toCam(w[0], w[1], w[2]));
    }
    var clipped = clipNear(cam);
    if (clipped.length < 3) return;
    var pts = [];
    for (var j = 0; j < clipped.length; j++) pts.push(project(clipped[j]));
    fillPolygon(pts, color);
  }

  function dim(hex, factor) {
    var r = Math.round(parseInt(hex.substr(1, 2), 16) * factor);
    var g = Math.round(parseInt(hex.substr(3, 2), 16) * factor);
    var b = Math.round(parseInt(hex.substr(5, 2), 16) * factor);
    return 'rgb(' + clamp(r, 0, 255) + ',' + clamp(g, 0, 255) + ',' + clamp(b, 0, 255) + ')';
  }

  // ---- render ----
  function drawSky() {
    var sky = ctx.createLinearGradient(0, 0, 0, H);
    sky.addColorStop(0, '#7fc9ee');
    sky.addColorStop(0.6, '#c0e2ed');
    sky.addColorStop(1, '#d8c89a');
    ctx.fillStyle = sky;
    ctx.fillRect(0, 0, W, H);
  }

  function drawGroundQuad(q) {
    drawWorldPolygon(
      [[q.x1, 0, q.z1], [q.x2, 0, q.z1], [q.x2, 0, q.z2], [q.x1, 0, q.z2]],
      q.color
    );
  }

  function collectBoxFaces(o, faceList) {
    var hw = o.w / 2, hd = o.d / 2, y0 = 0, y1 = o.h;
    var c = [
      toCam(o.x - hw, y0, o.z - hd),
      toCam(o.x + hw, y0, o.z - hd),
      toCam(o.x + hw, y0, o.z + hd),
      toCam(o.x - hw, y0, o.z + hd),
      toCam(o.x - hw, y1, o.z - hd),
      toCam(o.x + hw, y1, o.z - hd),
      toCam(o.x + hw, y1, o.z + hd),
      toCam(o.x - hw, y1, o.z + hd),
    ];
    var faces = [
      { idx: [0, 1, 5, 4], color: dim(o.color, 0.80) },  // -z south
      { idx: [3, 2, 6, 7], color: dim(o.color, 0.80) },  // +z north
      { idx: [0, 3, 7, 4], color: dim(o.color, 0.92) },  // -x west
      { idx: [1, 2, 6, 5], color: dim(o.color, 0.92) },  // +x east
      { idx: [4, 5, 6, 7], color: o.roof || dim(o.color, 1.05) },  // top
    ];
    for (var f = 0; f < faces.length; f++) {
      var verts = [];
      for (var k = 0; k < faces[f].idx.length; k++) verts.push(c[faces[f].idx[k]]);
      var clipped = clipNear(verts);
      if (clipped.length < 3) continue;
      var depth = 0;
      for (var v = 0; v < clipped.length; v++) if (clipped[v].z > depth) depth = clipped[v].z;
      faceList.push({ clipped: clipped, color: faces[f].color, depth: depth });
    }
  }

  function drawObstacles() {
    var list = [];
    for (var i = 0; i < world.obstacles.length; i++) {
      var o = world.obstacles[i];
      var dx0 = o.x - player.x, dz0 = o.z - player.z;
      if (dx0 * dx0 + dz0 * dz0 > 200 * 200) continue;  // distance cull
      collectBoxFaces(o, list);
    }
    list.sort(function (a, b) { return b.depth - a.depth; });
    for (var j = 0; j < list.length; j++) {
      var f = list[j];
      var pts = [];
      for (var k = 0; k < f.clipped.length; k++) pts.push(project(f.clipped[k]));
      fillPolygon(pts, f.color);
    }
  }

  function drawHood() {
    var cx = W / 2;
    ctx.fillStyle = '#181820';
    ctx.beginPath();
    ctx.ellipse(cx, H + 50, W * 0.55, 100, 0, Math.PI, 0, true);
    ctx.fill();
    ctx.fillStyle = '#0a0a0c';
    ctx.fillRect(0, H - 10, W, 10);

    var tilt = (keys.ArrowLeft ? -0.45 : 0) + (keys.ArrowRight ? 0.45 : 0);
    ctx.save();
    ctx.translate(cx, H - 22);
    ctx.rotate(tilt);
    ctx.strokeStyle = '#0e0e10';
    ctx.lineWidth = 8;
    ctx.beginPath();
    ctx.arc(0, 0, 32, 0, Math.PI * 2);
    ctx.stroke();
    ctx.lineWidth = 5;
    ctx.beginPath();
    ctx.moveTo(-32, 0); ctx.lineTo(32, 0);
    ctx.moveTo(0, 0);   ctx.lineTo(0, 26);
    ctx.stroke();
    ctx.restore();
  }

  function drawHud() {
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(W - 200, 12, 188, 60);
    ctx.strokeStyle = 'rgba(255,255,255,0.18)';
    ctx.lineWidth = 1;
    ctx.strokeRect(W - 200, 12, 188, 60);
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 22px ui-monospace, monospace';
    var mph = Math.floor(Math.abs(player.speed) * 2.237);
    var label = player.speed < -0.1 ? 'REV ' : 'MPH ';
    ctx.fillText(label + mph, W - 188, 40);
    ctx.fillStyle = '#2a2a30';
    ctx.fillRect(W - 188, 50, 168, 8);
    ctx.fillStyle = player.speed < 0 ? '#7a90ff' : '#ff8030';
    ctx.fillRect(W - 188, 50, 168 * Math.min(1, Math.abs(player.speed) / maxSpeed), 8);
  }

  function render() {
    drawSky();
    for (var i = 0; i < world.ground.length; i++) drawGroundQuad(world.ground[i]);
    for (var j = 0; j < world.lines.length;  j++) drawGroundQuad(world.lines[j]);
    drawObstacles();
    drawHood();
    drawHud();
  }

  // ---- main loop ----
  var last = 0, frameCount = 0, fpsTime = 0;
  function loop(t) {
    var dt = Math.min(0.05, (t - last) / 1000);
    last = t;
    update(dt);
    render();
    frameCount++;
    fpsTime += dt;
    if (fpsTime >= 0.5) {
      fpsEl.textContent = (frameCount / fpsTime).toFixed(0) + ' fps';
      frameCount = 0;
      fpsTime = 0;
    }
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(function (t) { last = t; requestAnimationFrame(loop); });
})();
