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

  // ---- world / map: built from a route DSL ----
  // The drive is a chain of perpendicular corridors. Each segment is directed,
  // so the direction change between consecutive segments *is* the turn
  // (E->N = left, N->E = right, N->W = left). Per segment:
  //   width  : corridor width, in car-widths
  //   dir    : travel / facing direction (E N W S)
  //   right  : scenery on your right  \ cars | buildings | trees | houses | sky
  //   left   : scenery on your left   / ('a/b' alternates the two kinds)
  //   behind : caps the back end — the wrong-way deterrent: fire | building
  //   miles  : length (or m: meters, for the short lot segments)
  //   lines  : painted lane lines
  // A fire sits at a segment's back, so on the correct path it is always behind
  // you (off-screen); you only meet it by turning the wrong way into the back.
  var ROUTE = [
    { name: 'parking space',   width: 1, dir: 'E', right: 'cars',           left: 'cars',           behind: 'building', m: 6 },
    { name: 'parking lot',     width: 3, dir: 'N', right: 'cars/buildings', left: 'cars/buildings', behind: 'fire',     m: 48 },
    { name: 'Autumn Pines Rd', width: 2, dir: 'E', right: 'buildings',      left: 'trees',          behind: 'fire',     miles: 0.25 },
    { name: 'Murrell Rd',      width: 4, dir: 'N', right: 'sky',            left: 'sky',            behind: 'fire',     miles: 3, lines: true },
    { name: 'Levitt Pkwy',     width: 2, dir: 'W', right: 'houses',         left: 'trees',          behind: 'building', miles: 1 },
  ];

  var CARW = 2.6;   // meters of corridor per "car width"
  var MILE = 300;   // compressed meters per mile (tunable; keeps the drive sane)
  var DIR = { E: [1, 0], N: [0, 1], W: [-1, 0], S: [0, -1] };
  var DIR_HEADING = { E: Math.PI / 2, N: 0, W: -Math.PI / 2, S: Math.PI };
  var CAR_COLORS = ['#9b2c2c', '#2e4d8a', '#7a6730', '#88307a', '#327832',
                    '#5c3c3c', '#a08020', '#107050', '#503070', '#205080'];
  var BUILD_COLORS = ['#c8a878', '#aa9468', '#b89876', '#9c8470', '#b0986e'];
  var HOUSE_COLORS = ['#cdb89a', '#b9a888', '#d2c0a0', '#c2ad8a'];
  var ROOFS = ['#5a3a2a', '#4a3328', '#46342a', '#52382a'];

  function carEW(x, z, color) {  // points east/west (length along x)
    return { kind: 'car', x: x, z: z, w: 4.5, h: 1.45, d: 1.8, color: color, axis: 'ew' };
  }
  function carNS(x, z, color) {  // points north/south (length along z)
    return { kind: 'car', x: x, z: z, w: 1.8, h: 1.45, d: 4.5, color: color, axis: 'ns' };
  }
  function fire(x, z, w, d, h) {
    return { kind: 'fire', x: x, z: z, w: w, d: d, h: h };
  }
  function tree(x, z) {  // collision footprint ~foliage so a row reads as a wall
    return { kind: 'tree', x: x, z: z, w: 2.6, h: 5.2, d: 2.6 };
  }
  function box(kind, x, z, w, h, d, color, roof) {
    return { kind: kind, x: x, z: z, w: w, h: h, d: d, color: color, roof: roof };
  }

  // axis-aligned ground rect for a corridor, extended at each junction by the
  // neighbour's half-width so perpendicular corridors meet in a paved corner.
  function corridorRect(ax, az, bx, bz, d, W, extStart, extEnd, color) {
    var sx = ax - d[0] * extStart, sz = az - d[1] * extStart;
    var ex = bx + d[0] * extEnd,   ez = bz + d[1] * extEnd;
    var px = -d[1], pz = d[0];
    var xs = [sx + px * W / 2, sx - px * W / 2, ex + px * W / 2, ex - px * W / 2];
    var zs = [sz + pz * W / 2, sz - pz * W / 2, ez + pz * W / 2, ez - pz * W / 2];
    return { x1: Math.min.apply(null, xs), z1: Math.min.apply(null, zs),
             x2: Math.max.apply(null, xs), z2: Math.max.apply(null, zs), color: color };
  }

  var SCENERY_STEP = { cars: 5, trees: 3.5, buildings: 14, houses: 13 };
  var SCENERY_GAP  = { cars: 1.6, trees: 1.2, buildings: 5.5, houses: 4.5 };

  function pushScenery(kind, cx, cz, alongX, k, obs) {
    if (kind === 'cars') {
      var c = CAR_COLORS[(k * 3) % CAR_COLORS.length];
      obs.push(alongX ? carEW(cx, cz, c) : carNS(cx, cz, c));
    } else if (kind === 'trees') {
      obs.push(tree(cx, cz));
    } else if (kind === 'buildings') {
      obs.push(box('building', cx, cz, alongX ? 12 : 9, 6.5, alongX ? 9 : 12,
                   BUILD_COLORS[k % BUILD_COLORS.length], ROOFS[k % ROOFS.length]));
    } else if (kind === 'houses') {
      obs.push(box('house', cx, cz, alongX ? 8 : 7, 4.5, alongX ? 7 : 8,
                   HOUSE_COLORS[k % HOUSE_COLORS.length], ROOFS[k % ROOFS.length]));
    }
  }

  // line a corridor side (right/left of travel) with a row of scenery
  function placeSide(type, side, ax, az, d, W, lenM, obs) {
    if (!type || type === 'sky') return;
    var perp = (side === 'right') ? [d[1], -d[0]] : [-d[1], d[0]];
    var alongX = (d[0] !== 0);
    var kinds = type.split('/');
    var step = SCENERY_STEP[kinds[0]] || 6;
    var k = 0;
    for (var t = step * 0.5; t < lenM; t += step, k++) {
      var kind = kinds[k % kinds.length];
      var edge = W / 2 + (SCENERY_GAP[kind] || 2);
      pushScenery(kind, ax + d[0] * t + perp[0] * edge,
                        az + d[1] * t + perp[1] * edge, alongX, k, obs);
    }
  }

  function addLaneLines(ax, az, d, hw, lenM, lines) {
    var alongX = (d[0] !== 0), t;
    for (t = 0; t < lenM; t += 6) {  // dashed yellow centerline
      if (alongX) lines.push({ x1: ax + d[0] * t, z1: az - 0.15,
                               x2: ax + d[0] * (t + 3), z2: az + 0.15, color: '#e8c840' });
      else        lines.push({ x1: ax - 0.15, z1: az + d[1] * t,
                               x2: ax + 0.15, z2: az + d[1] * (t + 3), color: '#e8c840' });
    }
    if (alongX) {  // white edges (assumes a positive-axis corridor)
      lines.push({ x1: ax, z1: az - hw + 0.2, x2: ax + d[0] * lenM, z2: az - hw + 0.4, color: '#cccccc' });
      lines.push({ x1: ax, z1: az + hw - 0.4, x2: ax + d[0] * lenM, z2: az + hw - 0.2, color: '#cccccc' });
    } else {
      lines.push({ x1: ax - hw + 0.2, z1: az, x2: ax - hw + 0.4, z2: az + d[1] * lenM, color: '#cccccc' });
      lines.push({ x1: ax + hw - 0.4, z1: az, x2: ax + hw - 0.2, z2: az + d[1] * lenM, color: '#cccccc' });
    }
  }

  function buildRoute() {
    var ground = [{ x1: -600, z1: -120, x2: 320, z2: 1700, color: '#2f7a30' }];
    var lines = [], obs = [];
    var ax = 0, az = 0, start = null, end = null, colorN = 0;
    for (var i = 0; i < ROUTE.length; i++) {
      var s = ROUTE[i], d = DIR[s.dir];
      var W = s.width * CARW, hw = W / 2;
      var lenM = (s.m != null) ? s.m : s.miles * MILE;
      var bx = ax + d[0] * lenM, bz = az + d[1] * lenM;
      var prevHW = (i > 0) ? ROUTE[i - 1].width * CARW / 2 : 0;
      var nextHW = (i < ROUTE.length - 1) ? ROUTE[i + 1].width * CARW / 2 : 0;

      ground.push(corridorRect(ax, az, bx, bz, d, W, prevHW, nextHW,
                               (s.miles == null) ? '#3a3a40' : '#2c2c30'));
      if (s.lines) addLaneLines(ax, az, d, hw, lenM, lines);
      placeSide(s.right, 'right', ax, az, d, W, lenM, obs);
      placeSide(s.left,  'left',  ax, az, d, W, lenM, obs);

      // back-end cap: placed so its near face clears the corridor start
      if (s.behind === 'fire') {
        var off = prevHW + 14;  // down the block, not right at the corner
        obs.push(fire(ax - d[0] * off, az - d[1] * off, Math.max(W, 6), 5, 6.5));
      } else if (s.behind === 'building') {
        var bo = prevHW + 5.5, alongX = (d[0] !== 0);
        obs.push(box('building', ax - d[0] * bo, az - d[1] * bo,
                     alongX ? 8 : W + 4, 6.5, alongX ? W + 4 : 8,
                     BUILD_COLORS[colorN++ % BUILD_COLORS.length], ROOFS[i % ROOFS.length]));
      }

      if (i === 0) start = { x: ax, z: az, heading: DIR_HEADING[s.dir] };
      if (i === ROUTE.length - 1) end = { x: bx, z: bz, dir: d };
      ax = bx; az = bz;
    }
    return { ground: ground, lines: lines, obstacles: obs, start: start, end: end };
  }

  var built = buildRoute();
  var world = { ground: built.ground, lines: built.lines, obstacles: built.obstacles };

  // ---- player ----
  var startX = built.start.x, startZ = built.start.z;
  var player = { x: startX, z: startZ, heading: built.start.heading, speed: 0 };
  var routeEnd = built.end;  // { x, z, dir } — drive past it -> end of map
  var gameOver = false;
  var gameOverReason = '';
  var paused = false;

  // ---- input ----
  var keys = {};
  window.addEventListener('keydown', function (e) {
    if (e.code === 'Space') { paused = !paused; e.preventDefault(); return; }
    keys[e.code] = true;
    if (e.code === 'ArrowUp' || e.code === 'ArrowDown' ||
        e.code === 'ArrowLeft' || e.code === 'ArrowRight') e.preventDefault();
  });
  window.addEventListener('keyup', function (e) { keys[e.code] = false; });

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  // ---- update ----
  function update(dt) {
    if (gameOver || paused) return;

    // Super-simple physics: input is the *only* thing that changes
    // speed/heading. Collision blocks position only — it never touches
    // speed. If you're pinned against a wall, steer to a clear angle and
    // you drive away at whatever speed you held.
    if (keys.ArrowUp)   player.speed += mode.accel * dt;
    if (keys.ArrowDown) player.speed -= mode.brake * dt;
    player.speed = clamp(player.speed, 0, mode.maxSpeed);

    var steerInput = (keys.ArrowLeft ? -1 : 0) + (keys.ArrowRight ? 1 : 0);
    player.heading += steerInput * 0.8 * dt;  // rad/s; gentler = finer control

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

    // boundary check — drive past the end of the last segment and the run ends
    if ((player.x - routeEnd.x) * routeEnd.dir[0] +
        (player.z - routeEnd.z) * routeEnd.dir[1] > 0) {
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

  // ---- tree composition (trunk + foliage) ----
  function treeParts(t) {
    return [
      { x: t.x, y: 0,   z: t.z, w: 0.5, h: 2.2, d: 0.5, color: '#6b4a2a' },
      { x: t.x, y: 2.0, z: t.z, w: 2.6, h: 3.2, d: 2.6, color: '#2f6b2e', roof: '#3f8a3a' },
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
      } else if (o.kind === 'tree') {
        var tparts = treeParts(o);
        for (var tp = 0; tp < tparts.length; tp++) collectBoxFaces(tparts[tp], list);
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

  function drawPaused() {
    ctx.fillStyle = 'rgba(0, 0, 0, 0.55)';
    ctx.fillRect(0, 0, W, H);
    ctx.textAlign = 'center';
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 42px ui-monospace, monospace';
    ctx.fillText('PAUSED', W / 2, H / 2 - 8);
    ctx.font = '16px ui-monospace, monospace';
    ctx.fillStyle = '#bbb';
    ctx.fillText('Press space to resume.', W / 2, H / 2 + 24);
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
    else if (paused) drawPaused();
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
