(function () {
  'use strict';

  // ---------- canvas / constants ----------
  var canvas = document.getElementById('c');
  var ctx = canvas.getContext('2d');
  var W = canvas.width;
  var H = canvas.height;
  var fpsEl = document.getElementById('fps');

  var FOV = 100;
  var cameraDepth = 1 / Math.tan((FOV / 2) * Math.PI / 180);
  var cameraHeight = 1000;
  var roadWidth = 2000;
  var segmentLength = 200;
  var lanes = 3;
  var drawDistance = 300;
  var fogStart = 0.6;   // fraction of drawDistance where fog kicks in

  var COLORS = {
    sky: '#5fb6e6',
    skyTop: '#9bd7f0',
    horizon: '#fae9a4',
    fog: '#a0c8a0',
    LIGHT:  { road: '#6b6b6b', grass: '#10aa10', rumble: '#dddddd', lane: '#f4f4f4' },
    DARK:   { road: '#5f5f5f', grass: '#0a9a0a', rumble: '#bb3333' },
    START:  { road: '#ffffff', grass: '#10aa10', rumble: '#ffffff' },
    FINISH: { road: '#222222', grass: '#10aa10', rumble: '#222222' }
  };

  // ---------- track ----------
  var segments = [];
  var trackLength = 0;

  function lastY() {
    return segments.length === 0 ? 0 : segments[segments.length - 1].p2.world.y;
  }

  function addSegment(curve, y) {
    var n = segments.length;
    segments.push({
      index: n,
      p1: { world: { y: lastY(), z: n * segmentLength }, camera: {}, screen: {} },
      p2: { world: { y: y,        z: (n + 1) * segmentLength }, camera: {}, screen: {} },
      curve: curve,
      sprites: [],
      color: (Math.floor(n / 3) % 2) ? COLORS.DARK : COLORS.LIGHT
    });
  }

  function easeIn(a, b, p)    { return a + (b - a) * p * p; }
  function easeInOut(a, b, p) { return a + (b - a) * ((-Math.cos(p * Math.PI) / 2) + 0.5); }

  function addRoad(enter, hold, leave, curve, yDelta) {
    var startY = lastY();
    var endY = startY + yDelta;
    var total = enter + hold + leave;
    var n;
    for (n = 0; n < enter; n++) addSegment(easeIn(0, curve, n / enter),      easeInOut(startY, endY, n / total));
    for (n = 0; n < hold;  n++) addSegment(curve,                             easeInOut(startY, endY, (enter + n) / total));
    for (n = 0; n < leave; n++) addSegment(easeInOut(curve, 0, n / leave),   easeInOut(startY, endY, (enter + hold + n) / total));
  }

  function addStraight(n) { addRoad(n, n, n, 0, 0); }
  function addCurve(n, curve) { addRoad(n, n, n, curve, 0); }
  function addHill(n, height) { addRoad(n, n, n, 0, height); }
  function addLowRoller(n, curve, height) { addRoad(n, n, n, curve, height); }

  function addSprite(segIndex, side, kind) {
    var seg = segments[segIndex];
    if (!seg) return;
    seg.sprites.push({ side: side, kind: kind });
  }

  function buildTrack() {
    addStraight(30);
    addCurve(60, 2);
    addStraight(20);
    addHill(40, 1500);
    addCurve(60, -4);
    addStraight(30);
    addLowRoller(40, 2, -800);
    addCurve(50, 5);
    addStraight(30);
    addHill(40, -1200);
    addCurve(80, -6);
    addStraight(40);
    addHill(60, 2200);
    addCurve(60, 4);
    addStraight(30);
    addCurve(80, -3);
    addLowRoller(40, -2, 900);
    addStraight(50);

    // mark start & finish
    segments[0].color = COLORS.START;
    segments[1].color = COLORS.START;
    segments[2].color = COLORS.START;
    segments[segments.length - 1].color = COLORS.FINISH;
    segments[segments.length - 2].color = COLORS.FINISH;
    segments[segments.length - 3].color = COLORS.FINISH;

    // sprinkle trees + signs
    var i;
    for (i = 20; i < segments.length; i += 3 + Math.floor(Math.random() * 5)) {
      var side = Math.random() < 0.5 ? -1 : 1;
      var kind = Math.random() < 0.85 ? 'tree' : 'sign';
      addSprite(i, side, kind);
    }
    // dense roadside tree wall in the distance
    for (i = 5; i < segments.length; i += 2) {
      if (Math.random() < 0.4) addSprite(i, Math.random() < 0.5 ? -1 : 1, 'tree');
    }
    // a few cones in the curves
    for (i = 0; i < segments.length; i++) {
      if (Math.abs(segments[i].curve) > 3 && Math.random() < 0.18) {
        addSprite(i, segments[i].curve > 0 ? -1 : 1, 'cone');
      }
    }

    trackLength = segments.length * segmentLength;
  }

  function findSegment(z) {
    return segments[Math.floor(z / segmentLength) % segments.length];
  }

  // ---------- projection ----------
  function project(p, camX, camY, camZ) {
    p.camera.x = (p.world.x || 0) - camX;
    p.camera.y = (p.world.y || 0) - camY;
    p.camera.z = p.world.z - camZ;
    p.screen.scale = cameraDepth / p.camera.z;
    p.screen.x = Math.round((W / 2) + (p.screen.scale * p.camera.x * W / 2));
    p.screen.y = Math.round((H / 2) - (p.screen.scale * p.camera.y * H / 2));
    p.screen.w = Math.round(p.screen.scale * roadWidth * W / 2);
  }

  // ---------- player ----------
  var player = {
    z: 0,
    speed: 0,
    x: 0
  };
  var maxSpeed   = segmentLength * 60;
  var accel      = maxSpeed / 4;
  var brakeDecel = -maxSpeed;
  var handDecel  = -maxSpeed * 1.4;
  var coastDecel = -maxSpeed / 6;
  var offRoadDecel = -maxSpeed / 1.5;
  var offRoadLimit = maxSpeed / 4;
  var centrifugal = 0.35;

  var keys = {};
  window.addEventListener('keydown', function (e) {
    keys[e.code] = true;
    if (e.code === 'ArrowUp' || e.code === 'ArrowDown' ||
        e.code === 'ArrowLeft' || e.code === 'ArrowRight' ||
        e.code === 'Space') e.preventDefault();
  });
  window.addEventListener('keyup', function (e) { keys[e.code] = false; });

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

  function update(dt) {
    var seg = findSegment(player.z);
    var speedPct = player.speed / maxSpeed;
    var steerSpeed = dt * 2.0 * speedPct;

    player.z = (player.z + dt * player.speed) % trackLength;
    if (player.z < 0) player.z += trackLength;

    if (keys.ArrowLeft)  player.x -= steerSpeed;
    if (keys.ArrowRight) player.x += steerSpeed;

    // centrifugal force pushes outward on curves
    player.x -= (dt * speedPct * seg.curve * centrifugal);

    if (keys.Space)            player.speed = clamp(player.speed + handDecel * dt, 0, maxSpeed);
    else if (keys.ArrowDown)   player.speed = clamp(player.speed + brakeDecel * dt, 0, maxSpeed);
    else if (keys.ArrowUp)     player.speed = clamp(player.speed + accel * dt, 0, maxSpeed);
    else                       player.speed = clamp(player.speed + coastDecel * dt, 0, maxSpeed);

    // off-road slowdown + bumpiness handled by render
    if ((player.x < -1 || player.x > 1) && player.speed > offRoadLimit) {
      player.speed = clamp(player.speed + offRoadDecel * dt, 0, maxSpeed);
    }
    player.x = clamp(player.x, -3, 3);
  }

  // ---------- render ----------

  function fogFactor(n) {
    // 0 = fully clear (near), 1 = fully fogged (far)
    if (n < drawDistance * fogStart) return 0;
    var t = (n - drawDistance * fogStart) / (drawDistance * (1 - fogStart));
    return Math.min(1, t);
  }

  function mixColor(hex, fog) {
    if (fog <= 0) return hex;
    // hex like '#rrggbb'
    var r = parseInt(hex.substr(1, 2), 16);
    var g = parseInt(hex.substr(3, 2), 16);
    var b = parseInt(hex.substr(5, 2), 16);
    // fog is #a0c8a0 = (160, 200, 160)
    r = Math.round(r + (160 - r) * fog);
    g = Math.round(g + (200 - g) * fog);
    b = Math.round(b + (160 - b) * fog);
    return 'rgb(' + r + ',' + g + ',' + b + ')';
  }

  function polygon(x1, y1, x2, y2, x3, y3, x4, y4, color) {
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.lineTo(x3, y3);
    ctx.lineTo(x4, y4);
    ctx.closePath();
    ctx.fill();
  }

  function drawBackground() {
    // sky gradient
    var sky = ctx.createLinearGradient(0, 0, 0, H * 0.62);
    sky.addColorStop(0, COLORS.skyTop);
    sky.addColorStop(0.7, COLORS.sky);
    sky.addColorStop(1, COLORS.horizon);
    ctx.fillStyle = sky;
    ctx.fillRect(0, 0, W, H * 0.62);

    // ground (the part below the horizon, before road)
    var ground = ctx.createLinearGradient(0, H * 0.62, 0, H);
    ground.addColorStop(0, '#7fb872');
    ground.addColorStop(1, '#10aa10');
    ctx.fillStyle = ground;
    ctx.fillRect(0, H * 0.62 - 1, W, H * 0.38 + 1);

    // sun
    ctx.fillStyle = 'rgba(255, 230, 180, 0.85)';
    ctx.beginPath();
    ctx.arc(W * 0.7, H * 0.30, 40, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = 'rgba(255, 230, 180, 0.25)';
    ctx.beginPath();
    ctx.arc(W * 0.7, H * 0.30, 70, 0, Math.PI * 2);
    ctx.fill();

    // a few parallax clouds
    drawCloud(W * 0.12 - (player.z * 0.001) % W, H * 0.18, 80);
    drawCloud(W * 0.40 - (player.z * 0.0012) % W, H * 0.10, 110);
    drawCloud(W * 0.85 - (player.z * 0.0009) % W, H * 0.22, 70);
  }

  function drawCloud(x, y, w) {
    ctx.fillStyle = 'rgba(255,255,255,0.85)';
    ctx.beginPath();
    ctx.arc(x,         y,     w * 0.35, 0, Math.PI * 2);
    ctx.arc(x + w*0.3, y - 6, w * 0.30, 0, Math.PI * 2);
    ctx.arc(x + w*0.55,y,     w * 0.32, 0, Math.PI * 2);
    ctx.arc(x + w*0.25,y + 4, w * 0.28, 0, Math.PI * 2);
    ctx.fill();
  }

  function renderSegment(seg, fog) {
    var p1 = seg.p1.screen, p2 = seg.p2.screen;
    var roadColor   = mixColor(seg.color.road, fog);
    var grassColor  = mixColor(seg.color.grass, fog);
    var rumbleColor = mixColor(seg.color.rumble, fog);

    var r1 = Math.max(6, p1.w / 12);
    var r2 = Math.max(6, p2.w / 12);
    var l1 = Math.max(2, p1.w / 32);
    var l2 = Math.max(2, p2.w / 32);

    // grass band for this y-slice
    ctx.fillStyle = grassColor;
    ctx.fillRect(0, p2.y, W, p1.y - p2.y);

    // road
    polygon(p1.x - p1.w, p1.y,
            p1.x + p1.w, p1.y,
            p2.x + p2.w, p2.y,
            p2.x - p2.w, p2.y,
            roadColor);

    // rumble strips
    polygon(p1.x - p1.w - r1, p1.y,
            p1.x - p1.w,      p1.y,
            p2.x - p2.w,      p2.y,
            p2.x - p2.w - r2, p2.y,
            rumbleColor);
    polygon(p1.x + p1.w + r1, p1.y,
            p1.x + p1.w,      p1.y,
            p2.x + p2.w,      p2.y,
            p2.x + p2.w + r2, p2.y,
            rumbleColor);

    // lane stripes on LIGHT segments only (dashed effect)
    if (seg.color === COLORS.LIGHT) {
      var laneW1 = (p1.w * 2) / lanes;
      var laneW2 = (p2.w * 2) / lanes;
      var lx1 = p1.x - p1.w + laneW1;
      var lx2 = p2.x - p2.w + laneW2;
      var laneColor = mixColor(COLORS.LIGHT.lane, fog);
      for (var lane = 1; lane < lanes; lane++) {
        polygon(lx1 - l1 / 2, p1.y,
                lx1 + l1 / 2, p1.y,
                lx2 + l2 / 2, p2.y,
                lx2 - l2 / 2, p2.y,
                laneColor);
        lx1 += laneW1;
        lx2 += laneW2;
      }
    }
  }

  function renderSprite(seg, sp, fog) {
    // sprite "world width" — tuned per kind
    var worldW, worldH;
    if (sp.kind === 'tree') { worldW = 320; worldH = 640; }
    else if (sp.kind === 'sign') { worldW = 180; worldH = 260; }
    else { worldW = 80; worldH = 120; } // cone

    var scale = seg.p1.screen.scale;
    var destW = scale * worldW * (W / 2);
    var destH = scale * worldH * (W / 2);
    if (destW < 1 || destH < 1) return;

    // offset from road edge — sit just beyond the rumble
    var roadEdge = roadWidth + 100;
    var spriteOffset = sp.side * (roadEdge + (sp.kind === 'cone' ? -80 : 350));
    var destX = seg.p1.screen.x + (scale * spriteOffset * (W / 2));
    // anchor at base = p1.y; for cones sit on road surface
    var destY = seg.p1.screen.y - destH;

    // clip horizontally (cheap)
    if (destX + destW < 0 || destX - destW > W) return;

    if (sp.kind === 'tree')      drawTree(destX, destY, destW, destH, fog);
    else if (sp.kind === 'sign') drawSign(destX, destY, destW, destH, fog);
    else                         drawCone(destX, destY, destW, destH, fog);
  }

  function drawTree(x, y, w, h, fog) {
    // trunk
    ctx.fillStyle = mixColor('#5a3a1b', fog);
    ctx.fillRect(x - w * 0.07, y + h * 0.7, w * 0.14, h * 0.32);
    // foliage — three stacked triangles for a pine look
    var fill = mixColor('#1e7a2e', fog);
    ctx.fillStyle = fill;
    ctx.beginPath();
    ctx.moveTo(x,             y);
    ctx.lineTo(x + w * 0.50,  y + h * 0.42);
    ctx.lineTo(x - w * 0.50,  y + h * 0.42);
    ctx.closePath();
    ctx.fill();
    ctx.beginPath();
    ctx.moveTo(x,             y + h * 0.18);
    ctx.lineTo(x + w * 0.55,  y + h * 0.60);
    ctx.lineTo(x - w * 0.55,  y + h * 0.60);
    ctx.closePath();
    ctx.fill();
    ctx.beginPath();
    ctx.moveTo(x,             y + h * 0.36);
    ctx.lineTo(x + w * 0.60,  y + h * 0.78);
    ctx.lineTo(x - w * 0.60,  y + h * 0.78);
    ctx.closePath();
    ctx.fill();
  }

  function drawSign(x, y, w, h, fog) {
    // post
    ctx.fillStyle = mixColor('#5a3a1b', fog);
    ctx.fillRect(x - w * 0.06, y + h * 0.45, w * 0.12, h * 0.55);
    // board
    ctx.fillStyle = mixColor('#f5c937', fog);
    ctx.fillRect(x - w * 0.45, y, w * 0.9, h * 0.5);
    // border
    ctx.strokeStyle = mixColor('#1a1a1a', fog);
    ctx.lineWidth = Math.max(1, w * 0.03);
    ctx.strokeRect(x - w * 0.45, y, w * 0.9, h * 0.5);
    // "lettering" lines
    ctx.fillStyle = mixColor('#1a1a1a', fog);
    ctx.fillRect(x - w * 0.35, y + h * 0.10, w * 0.7, h * 0.05);
    ctx.fillRect(x - w * 0.35, y + h * 0.22, w * 0.7, h * 0.05);
    ctx.fillRect(x - w * 0.35, y + h * 0.34, w * 0.7, h * 0.05);
  }

  function drawCone(x, y, w, h, fog) {
    // base
    ctx.fillStyle = mixColor('#222222', fog);
    ctx.fillRect(x - w * 0.55, y + h * 0.85, w * 1.1, h * 0.15);
    // cone
    ctx.fillStyle = mixColor('#ff6a1f', fog);
    ctx.beginPath();
    ctx.moveTo(x,             y + h * 0.10);
    ctx.lineTo(x + w * 0.5,   y + h * 0.85);
    ctx.lineTo(x - w * 0.5,   y + h * 0.85);
    ctx.closePath();
    ctx.fill();
    // white stripe
    ctx.fillStyle = mixColor('#ffffff', fog);
    ctx.fillRect(x - w * 0.34, y + h * 0.50, w * 0.68, h * 0.10);
  }

  function drawCar() {
    // a little side-to-side bob when off-road
    var off = (player.x < -1 || player.x > 1) && player.speed > offRoadLimit
      ? Math.sin(performance.now() / 60) * 3 : 0;

    var cx = W / 2;
    var cy = H + 70 + off;

    // hood (big dark ellipse)
    ctx.fillStyle = '#1a1a22';
    ctx.beginPath();
    ctx.ellipse(cx, cy, W * 0.58, 110, 0, Math.PI, 0, true);
    ctx.fill();

    // hood highlight
    var grad = ctx.createLinearGradient(0, H - 80, 0, H);
    grad.addColorStop(0, 'rgba(255,255,255,0.10)');
    grad.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.ellipse(cx, cy - 10, W * 0.55, 80, 0, Math.PI, 0, true);
    ctx.fill();

    // dashboard band
    ctx.fillStyle = '#0a0a0c';
    ctx.fillRect(0, H - 12, W, 12);

    // steering wheel, tilted by input
    var tilt = (keys.ArrowLeft ? -0.45 : 0) + (keys.ArrowRight ? 0.45 : 0) + player.x * 0.15;
    var wx = cx;
    var wy = H - 22 + off * 0.4;
    ctx.save();
    ctx.translate(wx, wy);
    ctx.rotate(tilt);
    ctx.strokeStyle = '#0e0e10';
    ctx.lineWidth = 8;
    ctx.beginPath();
    ctx.arc(0, 0, 36, 0, Math.PI * 2);
    ctx.stroke();
    ctx.lineWidth = 6;
    ctx.beginPath();
    ctx.moveTo(-36, 0);
    ctx.lineTo(36, 0);
    ctx.moveTo(0, 0);
    ctx.lineTo(0, 30);
    ctx.stroke();
    ctx.restore();
  }

  function drawHud() {
    // speedo box
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(W - 200, 12, 188, 68);
    ctx.strokeStyle = 'rgba(255,255,255,0.2)';
    ctx.lineWidth = 1;
    ctx.strokeRect(W - 200, 12, 188, 68);

    ctx.fillStyle = '#fff';
    ctx.font = 'bold 22px ui-monospace, monospace';
    var mph = Math.floor(player.speed / segmentLength * 12);
    ctx.fillText('MPH ' + mph, W - 188, 40);

    // speedo bar
    ctx.fillStyle = '#2a2a30';
    ctx.fillRect(W - 188, 50, 168, 8);
    ctx.fillStyle = '#ff8030';
    ctx.fillRect(W - 188, 50, 168 * (player.speed / maxSpeed), 8);

    ctx.fillStyle = '#bbb';
    ctx.font = '12px ui-monospace, monospace';
    ctx.fillText('Z ' + Math.floor(player.z), W - 188, 76);

    // lap counter (left)
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(12, 12, 130, 36);
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 16px ui-monospace, monospace';
    var lap = Math.floor(player.z / trackLength);
    ctx.fillText('LAP ' + (lap + 1), 22, 36);
  }

  function render() {
    drawBackground();

    var baseSeg = findSegment(player.z);
    var basePct = (player.z % segmentLength) / segmentLength;
    var playerY = baseSeg.p1.world.y + (baseSeg.p2.world.y - baseSeg.p1.world.y) * basePct;

    var maxY = H;
    var x = 0;
    var dx = -(baseSeg.curve * basePct);

    var visible = [];
    var visN = [];

    for (var n = 0; n < drawDistance; n++) {
      var seg = segments[(baseSeg.index + n) % segments.length];
      var looped = seg.index < baseSeg.index;
      var camZ = player.z - (looped ? trackLength : 0);
      var camY = playerY + cameraHeight;

      project(seg.p1, (player.x * roadWidth) - x,        camY, camZ);
      project(seg.p2, (player.x * roadWidth) - x - dx,   camY, camZ);

      x  = x + dx;
      dx = dx + seg.curve;

      if (seg.p1.camera.z <= cameraDepth ||
          seg.p2.screen.y >= seg.p1.screen.y ||
          seg.p2.screen.y >= maxY) continue;

      var fog = fogFactor(n);
      renderSegment(seg, fog);
      visible.push(seg);
      visN.push(n);
      maxY = seg.p2.screen.y;
    }

    // sprites back-to-front (far first)
    for (var i = visible.length - 1; i >= 0; i--) {
      var s = visible[i];
      var f = fogFactor(visN[i]);
      for (var k = 0; k < s.sprites.length; k++) {
        renderSprite(s, s.sprites[k], f);
      }
    }

    drawCar();
    drawHud();
  }

  // ---------- main loop ----------
  var last = 0;
  var frameCount = 0;
  var fpsTime = 0;

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

  buildTrack();
  requestAnimationFrame(function (t) {
    last = t;
    requestAnimationFrame(loop);
  });
})();
