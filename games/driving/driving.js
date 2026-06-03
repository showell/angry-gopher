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
  // (player's right). Forward direction is (sin h, 0, cos h).
  var FOV = 70;
  var focal = (W / 2) / Math.tan((FOV / 2) * Math.PI / 180);
  var nearPlane = 0.3;
  var cameraHeight = 1.2;  // driver eye level (m)

  // ---- driving modes ----
  // Three planned modes; only parking-lot is wired up. Each mode tunes
  // speed/handling. Later, crossing zone triggers will transition between
  // them (parking lot -> neighborhood -> highway).
  var MODES = {
    parkingLot: {
      name: 'parking lot',
      maxSpeed: 12,       // ~27 mph
      accel: 4,
      brake: 10,
      handBrake: 18,
    },
    neighborhood: {       // placeholder, not yet entered
      name: 'neighborhood',
      maxSpeed: 16, accel: 7, brake: 14, handBrake: 22,
    },
    highway: {            // placeholder, not yet entered
      name: 'highway',
      maxSpeed: 32, accel: 10, brake: 18, handBrake: 28,
    },
  };
  var mode = MODES.parkingLot;
  document.title = 'driving — ' + mode.name;

  // ---- world / map (encoded in JS) ----
  // Parking lot with two facing rows; player starts mid-row facing the lane.
  // Exit driveway at the WEST end. Street runs east-west; correct route is
  // RIGHT (east) onto the street. Going LEFT (west) shows a fire ~quarter
  // mile away — that's the wrong-way cue.
  function car(x, z, color) {
    return { kind: 'car', x: x, z: z, w: 1.8, h: 1.45, d: 4.5, color: color };
  }

  var world = {
    ground: [
      { x1: -700, z1: -80, x2: 400, z2: 120, color: '#2f7a30' },  // grass everywhere
      { x1:  -25, z1: -12, x2:  16, z2:   8, color: '#3a3a40' },  // parking lot
      { x1:  -20, z1:   8, x2: -10, z2:  12, color: '#3a3a40' },  // exit driveway
      { x1: -700, z1:  12, x2: 400, z2:  22, color: '#2c2c30' },  // street
      { x1: -700, z1:  22, x2: 400, z2:  24, color: '#a0a0a8' },  // far sidewalk
      { x1: -700, z1:   9, x2: -25, z2:  12, color: '#9c9c9c' },  // near sidewalk west of lot
      { x1:   16, z1:   9, x2: 400, z2:  12, color: '#9c9c9c' },  // near sidewalk east of lot
    ],
    lines: [],  // populated below
    obstacles: [
      // player's row (player at x=0, z=-5.5)
      car(-10,   -5.5, '#9b2c2c'),
      car( -7.5, -5.5, '#2e4d8a'),
      car( -5,   -5.5, '#7a6730'),
      car( -2.5, -5.5, '#2d5060'),
      car(  2.5, -5.5, '#88307a'),
      car(  5,   -5.5, '#327832'),
      car(  7.5, -5.5, '#5c3c3c'),
      car( 10,   -5.5, '#787880'),
      car( 13,   -5.5, '#3a1ea0'),
      // opposite row
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
      // burnt warehouse — the wrong-way cue, far to the west
      { kind: 'burnt', x: -450, z: 30, w: 30, h: 6, d: 12, color: '#1a1a1a', roof: '#0a0808' },
    ],
  };

  // generate parking-spot stripes + street markings
  (function () {
    var x;
    for (x = -11.25; x <= 14.3; x += 2.5) {
      world.lines.push({ x1: x - 0.06, z1: -8.5, x2: x + 0.06, z2: -2.5, color: '#dadada' });
      world.lines.push({ x1: x - 0.06, z1:  2.5, x2: x + 0.06, z2:  8.5, color: '#dadada' });
    }
    // dashed yellow centerline; extend across the whole drivable street
    for (x = -700; x < 400; x += 6) {
      world.lines.push({ x1: x, z1: 16.85, x2: x + 3, z2: 17.15, color: '#e8c840' });
    }
    // white edge lines
    world.lines.push({ x1: -700, z1: 12.15, x2: 400, z2: 12.30, color: '#dadada' });
    world.lines.push({ x1: -700, z1: 21.70, x2: 400, z2: 21.85, color: '#dadada' });
  })();

  // ---- player ----
  var startX = 0, startZ = -5.5;
  var player = { x: startX, z: startZ, heading: 0, speed: 0 };
  var maxTravelDist = 250;  // m from start; beyond this, the game ends
  var gameOver = false;
  var gameOverReason = '';

  // ---- input ----
  var keys = {};
  window.addEventListener('keydown', function (e) {
    keys[e.code] = true;
    if (e.code === 'ArrowUp' || e.code === 'ArrowDown' ||
        e.code === 'ArrowLeft' || e.code === 'ArrowRight') e.preventDefault();
  });
  window.addEventListener('keyup', function (e) { keys[e.code] = false; });

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  // ---- update ----
  function update(dt) {
    if (gameOver) return;

    // Super-simple physics: input is the *only* thing that changes
    // speed/heading. Collision blocks position only — it never touches
    // speed. If you're pinned against a wall, steer to a clear angle and
    // you drive away at whatever speed you held.
    if (keys.ArrowUp)   player.speed += mode.accel * dt;
    if (keys.ArrowDown) player.speed -= mode.brake * dt;
    player.speed = clamp(player.speed, 0, mode.maxSpeed);

    var steerInput = (keys.ArrowLeft ? -1 : 0) + (keys.ArrowRight ? 1 : 0);
    player.heading += steerInput * 1.4 * dt;

    var dx = Math.sin(player.heading) * player.speed * dt;
    var dz = Math.cos(player.heading) * player.speed * dt;
    if (!collides(player.x + dx, player.z + dz)) {
      player.x += dx;
      player.z += dz;
    } else if (!collides(player.x + dx, player.z)) {
      player.x += dx;
    } else if (!collides(player.x, player.z + dz)) {
      player.z += dz;
    }
    // else: pinned this frame — position unchanged, speed unchanged.

    // boundary check — drive too far in any direction and the run ends
    var ddx = player.x - startX, ddz = player.z - startZ;
    if (ddx * ddx + ddz * ddz > maxTravelDist * maxTravelDist) {
      gameOver = true;
      gameOverReason = (player.x < startX - 10) ? 'wrong way' : 'end of map';
      player.speed = 0;
    }
  }

  function collides(x, z) {
    var pad = 0.7;
    for (var i = 0; i < world.obstacles.length; i++) {
      var o = world.obstacles[i];
      var hw = o.w / 2 + pad;
      var hd = o.d / 2 + pad;
      if (x > o.x - hw && x < o.x + hw && z > o.z - hd && z < o.z + hd) return true;
    }
    return false;
  }

  // ---- transform / clip / project ----
  function toCam(wx, wy, wz) {
    var dx = wx - player.x;
    var dy = wy - cameraHeight;
    var dz = wz - player.z;
    var ch = Math.cos(player.heading);
    var sh = Math.sin(player.heading);
    return { x: ch * dx - sh * dz, y: dy, z: sh * dx + ch * dz };
  }

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

  // ---- car composition (body + cabin) ----
  // Each parked car renders as two stacked boxes. The cabin has darker
  // side faces (tinted glass) and a body-toned roof. Identical per-car
  // apart from body color, per Steve's spec.
  function carParts(c) {
    return [
      { x: c.x, y: 0,    z: c.z, w: c.w,        h: 0.95, d: c.d,        color: c.color },
      { x: c.x, y: 0.95, z: c.z, w: c.w * 0.85, h: 0.55, d: c.d * 0.55,
        color: '#2c2c34', roof: dim(c.color, 0.85) },
    ];
  }

  // ---- box face collection ----
  function collectBoxFaces(o, faceList) {
    var hw = o.w / 2, hd = o.d / 2;
    var y0 = o.y || 0;
    var y1 = y0 + o.h;
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
      { idx: [0, 1, 5, 4], color: dim(o.color, 0.80) },   // -z south
      { idx: [3, 2, 6, 7], color: dim(o.color, 0.80) },   // +z north
      { idx: [0, 3, 7, 4], color: dim(o.color, 0.92) },   // -x west
      { idx: [1, 2, 6, 5], color: dim(o.color, 0.92) },   // +x east
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
      if (dx0 * dx0 + dz0 * dz0 > 800 * 800) continue;
      if (o.kind === 'car') {
        var parts = carParts(o);
        for (var p = 0; p < parts.length; p++) collectBoxFaces(parts[p], list);
      } else {
        collectBoxFaces(o, list);
      }
    }
    list.sort(function (a, b) { return b.depth - a.depth; });
    for (var j = 0; j < list.length; j++) {
      var f = list[j];
      var pts = [];
      for (var k = 0; k < f.clipped.length; k++) pts.push(project(f.clipped[k]));
      fillPolygon(pts, f.color);
    }
  }

  // ---- decorations drawn AFTER box faces ----
  function drawApartmentWindows() {
    for (var i = 0; i < world.obstacles.length; i++) {
      var a = world.obstacles[i];
      if (a.kind !== 'building') continue;
      var z = a.z - a.d / 2 - 0.04;  // just south of south face
      for (var row = 0; row < 2; row++) {
        var y = 1.6 + row * 2.4;
        for (var col = 0; col < 4; col++) {
          var cx = a.x - a.w / 2 + 1.8 + col * (a.w - 3.6) / 3;
          drawWorldPolygon([
            [cx - 0.7, y,        z],
            [cx + 0.7, y,        z],
            [cx + 0.7, y + 1.1,  z],
            [cx - 0.7, y + 1.1,  z],
          ], '#e8d890');
        }
      }
    }
  }

  function drawFire(t) {
    var fx = -450, fz = 30 - 6 - 0.4;  // just south of the burnt warehouse front
    // flame columns
    for (var i = 0; i < 11; i++) {
      var bx = fx + (i - 5) * 2.6;
      var topY = 7 + Math.sin(t * 5 + i * 0.7) * 1.4 + Math.cos(t * 3 + i * 1.3) * 0.7;
      drawWorldPolygon([
        [bx - 1.6, 4.5, fz],
        [bx + 1.6, 4.5, fz],
        [bx + 0.5, topY, fz],
        [bx - 0.5, topY, fz],
      ], '#f47820');
      var innerTop = topY - 1;
      drawWorldPolygon([
        [bx - 0.8, 5.2, fz - 0.05],
        [bx + 0.8, 5.2, fz - 0.05],
        [bx + 0.2, innerTop, fz - 0.05],
        [bx - 0.2, innerTop, fz - 0.05],
      ], '#fad440');
    }
    // smoke columns
    for (var s = 0; s < 5; s++) {
      var sx = fx + (s - 2) * 5 + Math.sin(t * 0.5 + s * 1.3) * 1.8;
      var bottomY = 9 + s * 2.5;
      var topY = bottomY + 5;
      drawWorldPolygon([
        [sx - 4.5, bottomY, fz + 0.1],
        [sx + 4.5, bottomY, fz + 0.1],
        [sx + 3.2, topY,    fz + 0.1],
        [sx - 3.2, topY,    fz + 0.1],
      ], '#3a3a40');
    }
  }

  // ---- chrome (sky / dashboard / HUD / game over) ----
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

  function drawDashboard() {
    // Subtle dashboard — Steve wants the view ahead clearer than v2.
    ctx.fillStyle = '#1a1a20';
    ctx.fillRect(0, H - 60, W, 60);
    ctx.fillStyle = '#0a0a0c';
    ctx.fillRect(0, H - 64, W, 4);
    // small hood-top hint
    ctx.fillStyle = '#23232c';
    ctx.beginPath();
    ctx.ellipse(W / 2, H - 50, W * 0.55, 22, 0, Math.PI, 0, true);
    ctx.fill();

    // steering wheel
    var tilt = (keys.ArrowLeft ? -0.45 : 0) + (keys.ArrowRight ? 0.45 : 0);
    ctx.save();
    ctx.translate(W / 2, H - 24);
    ctx.rotate(tilt);
    ctx.strokeStyle = '#0a0a0e';
    ctx.lineWidth = 6;
    ctx.beginPath();
    ctx.arc(0, 0, 26, 0, Math.PI * 2);
    ctx.stroke();
    ctx.lineWidth = 4;
    ctx.beginPath();
    ctx.moveTo(-26, 0); ctx.lineTo(26, 0);
    ctx.moveTo(0, 0);   ctx.lineTo(0, 22);
    ctx.stroke();
    ctx.restore();
  }

  function drawHud() {
    // speedo
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(W - 200, 12, 188, 60);
    ctx.strokeStyle = 'rgba(255,255,255,0.18)';
    ctx.lineWidth = 1;
    ctx.strokeRect(W - 200, 12, 188, 60);
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 22px ui-monospace, monospace';
    var mph = Math.floor(player.speed * 2.237);
    ctx.fillText('MPH ' + mph, W - 188, 40);
    ctx.fillStyle = '#2a2a30';
    ctx.fillRect(W - 188, 50, 168, 8);
    ctx.fillStyle = '#ff8030';
    ctx.fillRect(W - 188, 50, 168 * (player.speed / mode.maxSpeed), 8);

    // mode badge (top-left)
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(12, 12, 170, 36);
    ctx.strokeStyle = 'rgba(255,255,255,0.18)';
    ctx.strokeRect(12, 12, 170, 36);
    ctx.fillStyle = '#999';
    ctx.font = '10px ui-monospace, monospace';
    ctx.fillText('MODE', 22, 24);
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 13px ui-monospace, monospace';
    ctx.fillText(mode.name.toUpperCase(), 22, 41);
  }

  function drawGameOver() {
    ctx.fillStyle = 'rgba(0, 0, 0, 0.75)';
    ctx.fillRect(0, 0, W, H);
    ctx.textAlign = 'center';
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 42px ui-monospace, monospace';
    ctx.fillText(gameOverReason === 'wrong way' ? 'WRONG WAY' : 'END OF MAP', W / 2, H / 2 - 20);
    ctx.font = '16px ui-monospace, monospace';
    ctx.fillStyle = '#bbb';
    ctx.fillText(
      gameOverReason === 'wrong way'
        ? 'The fire is half a mile west — you went the wrong way.'
        : 'You drove past the prescribed route.',
      W / 2, H / 2 + 12
    );
    ctx.fillText('Reload (Ctrl+R) to start over.', W / 2, H / 2 + 36);
    ctx.textAlign = 'left';
  }

  function render(time) {
    drawSky();
    for (var i = 0; i < world.ground.length; i++) drawGroundQuad(world.ground[i]);
    for (var j = 0; j < world.lines.length;  j++) drawGroundQuad(world.lines[j]);
    drawObstacles();
    drawApartmentWindows();
    drawFire(time);
    drawDashboard();
    drawHud();
    if (gameOver) drawGameOver();
  }

  // ---- main loop ----
  var last = 0, frameCount = 0, fpsTime = 0;
  function loop(t) {
    var dt = Math.min(0.05, (t - last) / 1000);
    last = t;
    update(dt);
    render(t / 1000);
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
