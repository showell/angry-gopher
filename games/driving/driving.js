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
  // One prescribed route. Each turn is a T-junction: the desired path is one
  // branch, a fire blocks the other. You never see a fire on the right path —
  // only when you take the wrong turn. Going straight is blocked by scenery.
  //   start: parked facing EAST, cars + apartments across the lot ahead.
  //   1. pull forward EAST, turn LEFT  -> NORTH up the lane    (right = fire)
  //   2. at the exit,       turn RIGHT -> EAST on a small road (left  = fire)
  //   3. at its end,        turn LEFT  -> NORTH on a big road  (right = fire)
  //
  // Map is 2D: every object has a ground (x, z) footprint; obstacles also
  // carry a height, so they render as 3D boxes. Cars are axis-aligned, so
  // they come in two orientations — east/west (length along x) and
  // north/south (length along z).
  function carEW(x, z, color) {  // points east/west
    return { kind: 'car', x: x, z: z, w: 4.5, h: 1.45, d: 1.8, color: color, axis: 'ew' };
  }
  function carNS(x, z, color) {  // points north/south
    return { kind: 'car', x: x, z: z, w: 1.8, h: 1.45, d: 4.5, color: color, axis: 'ns' };
  }
  function fire(x, z, w, d, h) {
    return { kind: 'fire', x: x, z: z, w: w, d: d, h: h };
  }

  var world = {
    ground: [
      { x1: -120, z1: -60, x2: 180, z2: 420, color: '#2f7a30' },  // grass everywhere
      { x1:   -4, z1: -16, x2:  17, z2:  42, color: '#3a3a40' },  // parking lot
      { x1:  -46, z1:  41, x2:  90, z2:  51, color: '#2c2c30' },  // small road (E-W)
      { x1:   74, z1: -10, x2:  90, z2: 380, color: '#2c2c30' },  // larger road (N-S)
    ],
    lines: [],  // populated below
    obstacles: [
      // player's row, facing east (player at x=0, z=0; z=0 spot is empty)
      carEW(0, -6.6, '#9b2c2c'),
      carEW(0, -4.4, '#2e4d8a'),
      carEW(0, -2.2, '#7a6730'),
      carEW(0,  2.2, '#88307a'),
      carEW(0,  4.4, '#327832'),
      carEW(0,  6.6, '#5c3c3c'),
      // opposite row, facing west; gap at z=0 frames the fire across the lot
      carEW(13.5, -6.6, '#a08020'),
      carEW(13.5, -4.4, '#107050'),
      carEW(13.5, -2.2, '#503070'),
      carEW(13.5,  2.2, '#208058'),
      carEW(13.5,  4.4, '#7a5430'),
      carEW(13.5,  6.6, '#205080'),
      // 2-story apartments across the lot (face west toward the player)
      { kind: 'building', x: 26, z: -9, w: 8, h: 6.5, d: 12, color: '#c8a878', roof: '#5a3a2a' },
      { kind: 'building', x: 26, z:  3, w: 8, h: 6.5, d: 12, color: '#aa9468', roof: '#4a3328' },
      { kind: 'building', x: 26, z: 15, w: 8, h: 6.5, d: 12, color: '#b89876', roof: '#5a3a2a' },
      // a little life along the two roads
      carEW(30, 49, '#3a1ea0'),
      carEW(56, 49, '#a04040'),
      carNS(78, 130, '#403028'),
      carNS(78, 210, '#205080'),
      // far sides of the two road T-junctions (can't go straight; you turn)
      { kind: 'building', x: 6.75, z: 57, w: 14, h: 6,   d: 8,  color: '#9a8c70', roof: '#4a3a2a' },
      { kind: 'building', x: 98,   z: 46, w: 8,  h: 6.5, d: 14, color: '#b0986e', roof: '#52382a' },
      // blocks that hide each wrong-branch fire until you turn onto it.
      // west of the lane (left as you head north); SW corner of the big road.
      { kind: 'building', x: -10, z: 24, w: 14, h: 6.5, d: 32, color: '#8c9078', roof: '#3a4030' },
      { kind: 'building', x:  66, z: 24, w: 14, h: 6.5, d: 30, color: '#9c8470', roof: '#46342a' },
      // fires mark the WRONG turn at each T (never seen on the desired path)
      fire(6.75, -11, 8, 5, 6.5),   // T1: turning RIGHT (south) instead of left
      fire(-30,  46, 9, 6, 7),      // T2: turning LEFT  (west)  instead of right
      fire(82,    6, 12, 5, 6.5),   // T3: turning RIGHT (south) instead of left
    ],
  };

  // parking-spot stripes + road markings
  (function () {
    var x, z, i;
    var zb = [-7.7, -5.5, -3.3, -1.1, 1.1, 3.3, 5.5, 7.7];
    for (i = 0; i < zb.length; i++) {
      world.lines.push({ x1: -2.25, z1: zb[i] - 0.06, x2:  2.25, z2: zb[i] + 0.06, color: '#cfcfcf' });
      world.lines.push({ x1: 11.25, z1: zb[i] - 0.06, x2: 15.75, z2: zb[i] + 0.06, color: '#cfcfcf' });
    }
    // small road: dashed center (E-W) + white edge lines
    for (x = 2; x < 88; x += 6) {
      world.lines.push({ x1: x, z1: 45.85, x2: x + 3, z2: 46.15, color: '#e8c840' });
    }
    world.lines.push({ x1: 1, z1: 41.2, x2: 90, z2: 41.4, color: '#cccccc' });
    world.lines.push({ x1: 1, z1: 50.6, x2: 90, z2: 50.8, color: '#cccccc' });
    // larger road: dashed center (N-S) + lane lines each side
    for (z = 42; z < 378; z += 6) {
      world.lines.push({ x1: 81.85, z1: z, x2: 82.15, z2: z + 3, color: '#e8c840' });
    }
    world.lines.push({ x1: 77.9, z1: 42, x2: 78.1, z2: 380, color: '#cccccc' });
    world.lines.push({ x1: 85.9, z1: 42, x2: 86.1, z2: 380, color: '#cccccc' });
  })();

  // ---- player ----
  // Parked facing EAST (heading = +90deg) looking across the lot.
  var startX = 0, startZ = 0;
  var player = { x: startX, z: startZ, heading: Math.PI / 2, speed: 0 };
  var endZ = 360;  // drive this far north on the larger road -> end of map
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

    // boundary check — reaching the far north end of the larger road ends it
    if (player.z > endZ) {
      gameOver = true;
      gameOverReason = 'end of map';
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
    // Cabin is shorter along the car's length and slightly narrower across.
    var lw = (c.axis === 'ew') ? 0.55 : 0.85;  // x scale
    var ld = (c.axis === 'ew') ? 0.85 : 0.55;  // z scale
    return [
      { x: c.x, y: 0,    z: c.z, w: c.w,      h: 0.95, d: c.d,      color: c.color },
      { x: c.x, y: 0.95, z: c.z, w: c.w * lw, h: 0.55, d: c.d * ld,
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
      if (o.kind === 'fire') continue;  // flames are billboarded in drawFire
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
      var x = a.x - a.w / 2 - 0.04;  // just west of the west face (faces player)
      for (var row = 0; row < 2; row++) {
        var y = 1.6 + row * 2.4;
        for (var col = 0; col < 4; col++) {
          var cz = a.z - a.d / 2 + 1.8 + col * (a.d - 3.6) / 3;
          drawWorldPolygon([
            [x, y,        cz - 0.7],
            [x, y,        cz + 0.7],
            [x, y + 1.1,  cz + 0.7],
            [x, y + 1.1,  cz - 0.7],
          ], '#e8d890');
        }
      }
    }
  }

  // Liang-Barsky: does the segment (x0,z0)->(x1,z1) touch the AABB at all?
  function segHitsBox(x0, z0, x1, z1, minx, minz, maxx, maxz) {
    var dx = x1 - x0, dz = z1 - z0, t0 = 0, t1 = 1;
    var e = [[-dx, x0 - minx], [dx, maxx - x0], [-dz, z0 - minz], [dz, maxz - z0]];
    for (var i = 0; i < 4; i++) {
      var p = e[i][0], q = e[i][1];
      if (p === 0) { if (q < 0) return false; }
      else {
        var r = q / p;
        if (p < 0) { if (r > t1) return false; if (r > t0) t0 = r; }
        else       { if (r < t0) return false; if (r < t1) t1 = r; }
      }
    }
    return t0 <= t1;
  }

  // A fire is hidden whenever a building stands between it and the camera, so
  // you only see it once you've turned onto its (wrong) branch.
  function fireHidden(f) {
    for (var i = 0; i < world.obstacles.length; i++) {
      var o = world.obstacles[i];
      if (o.kind !== 'building') continue;
      if (segHitsBox(player.x, player.z, f.x, f.z,
                     o.x - o.w / 2, o.z - o.d / 2, o.x + o.w / 2, o.z + o.d / 2)) return true;
    }
    return false;
  }

  // Flames are camera-facing billboards: each column is a vertical quad whose
  // horizontal axis is perpendicular to the player->fire direction, so the
  // fire reads as a wall of flame from whatever angle you approach it.
  function drawFire(t) {
    for (var fi = 0; fi < world.obstacles.length; fi++) {
      var f = world.obstacles[fi];
      if (f.kind !== 'fire') continue;
      var dx = f.x - player.x, dz = f.z - player.z;
      if (dx * dx + dz * dz > 70 * 70) continue;  // only near its own junction
      if (fireHidden(f)) continue;                // blocked by a building
      var len = Math.sqrt(dx * dx + dz * dz) || 1;
      var rx = dz / len, rz = -dx / len;   // ground-plane right (perp to view)
      var cols = Math.max(5, Math.round(f.w / 0.9));
      var sp = f.w / cols;
      for (var i = 0; i < cols; i++) {
        var off = (i - (cols - 1) / 2) * sp;
        var bx = f.x + rx * off, bz = f.z + rz * off;
        var topY = f.h + Math.sin(t * 5 + i * 0.7) * 1.3 + Math.cos(t * 3 + i * 1.3) * 0.7;
        var hw = sp * 0.7, tw = sp * 0.25;
        drawWorldPolygon([
          [bx - rx * hw, 0.2,  bz - rz * hw],
          [bx + rx * hw, 0.2,  bz + rz * hw],
          [bx + rx * tw, topY, bz + rz * tw],
          [bx - rx * tw, topY, bz - rz * tw],
        ], '#f47820');
        var innerTop = topY - 1.2;
        drawWorldPolygon([
          [bx - rx * hw * 0.5, 1.0,      bz - rz * hw * 0.5],
          [bx + rx * hw * 0.5, 1.0,      bz + rz * hw * 0.5],
          [bx + rx * tw * 0.5, innerTop, bz + rz * tw * 0.5],
          [bx - rx * tw * 0.5, innerTop, bz - rz * tw * 0.5],
        ], '#fad440');
      }
      // smoke billowing above
      for (var s = 0; s < 4; s++) {
        var soff = (s - 1.5) * f.w / 4 + Math.sin(t * 0.5 + s * 1.3) * 1.5;
        var sx = f.x + rx * soff, sz = f.z + rz * soff;
        var by = f.h + 1 + s * 2.2, ty = by + 4.5, sw = f.w * 0.28;
        drawWorldPolygon([
          [sx - rx * sw,       by, sz - rz * sw],
          [sx + rx * sw,       by, sz + rz * sw],
          [sx + rx * sw * 0.7, ty, sz + rz * sw * 0.7],
          [sx - rx * sw * 0.7, ty, sz - rz * sw * 0.7],
        ], '#3a3a40');
      }
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
    ctx.fillText('END OF MAP', W / 2, H / 2 - 20);
    ctx.font = '16px ui-monospace, monospace';
    ctx.fillStyle = '#bbb';
    ctx.fillText('You made it out onto the main road.', W / 2, H / 2 + 12);
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
