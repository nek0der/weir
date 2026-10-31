// landing.js
// Weir — the landing page's scroll story and the frames' layout. Runs inline at the end of the page, so the frames have their size before the first paint.
(function () {
  var root = document.documentElement;

  /* ---------- The story's steps ---------- */
  var WINDOW_WIDTH = 1440, WINDOW_HEIGHT = 900, WINDOW_RATIO = WINDOW_WIDTH / WINDOW_HEIGHT;
  /* Each step frames one region (`r`) of the window, can dim the parts it is not about (`spot`), and can fade in a capture with a layer open (`img`).
     Regions and spots are [left, top, width, height] in the capture's points. Each step has a .cap in the same order. */
  var steps = [
    { r: [0, 0, 1440, 900] },
    { r: [960, 0, 480, 430], spot: [1054, 4, 380, 408], img: 'needs-attention' },
    { r: [90, 30, 1260, 840], img: 'all-projects' },
    { r: [960, 0, 480, 560], spot: [1122, 4, 311, 870] },
    { r: [322, 640, 794, 234], spot: [322, 49, 794, 825] }
  ];
  var cur = 0, caps = document.querySelectorAll('.cap');
  var clone = document.getElementById('win').cloneNode(true); clone.removeAttribute('id');
  /* The hero has already described the window to a screen reader. */
  var cloneImage = clone.querySelector('img'); cloneImage.alt = ''; cloneImage.loading = 'lazy';
  var sw = document.getElementById('sw'); sw.appendChild(clone);
  var f0 = document.getElementById('f0'), f1 = document.getElementById('f1'), s0 = f0.firstElementChild;
  var layers = {};
  steps.forEach(function (st) {
    if (!st.img) return;
    var im = document.createElement('img');
    im.alt = ''; im.className = 'layer'; im.loading = 'lazy';
    clone.insertBefore(im, clone.querySelector('.spot'));
    layers[st.img] = im;
  });
  var dots = document.getElementById('dots');
  steps.forEach(function () { dots.appendChild(document.createElement('li')); });

  /* ---------- Light and dark ---------- */
  /* Each look's captures load only when that look is shown. */
  var captures = JSON.parse(document.getElementById('captures').textContent);
  function applyCaptures() {
    var look = root.dataset.theme;
    var hero = captures.hero[look], heroImage = document.querySelector('#win > img');
    heroImage.sizes = document.getElementById('win').dataset.heroSizes;
    heroImage.srcset = hero.small + ' 1440w, ' + hero.large + ' 2880w';
    heroImage.src = hero.small;
    /* The story zooms in, so it always takes the large one, and only as the reader comes near. */
    clone.querySelector('img:not(.layer)').src = hero.large;
    Object.keys(layers).forEach(function (k) { layers[k].src = captures[k][look].large; });
  }
  applyCaptures();
  document.addEventListener('weir:theme-set', applyCaptures);

  /* ---------- Layout ---------- */
  function showLayer(step) {
    Object.keys(layers).forEach(function (k) { layers[k].classList.toggle('on', k === step.img); });
  }
  function place(el, frame, step) {
    var w = frame.clientWidth, h = frame.clientHeight, r = step.r;
    var s = Math.min(w / r[2], h / r[3]);
    /* Past the window's edge there is nothing to show, so it stays centered in what is left. */
    function along(room, size, from, length) {
      var scaled = size * s;
      return scaled <= room ? (room - scaled) / 2 : Math.min(0, Math.max(room - scaled, room / 2 - (from + length / 2) * s));
    }
    var x = along(w, WINDOW_WIDTH, r[0], r[2]);
    var y = along(h, WINDOW_HEIGHT, r[1], r[3]);
    el.style.transform = 'translate(' + x + 'px,' + y + 'px) scale(' + s + ')';
  }
  function dim(step) {
    var spot = clone.querySelector('.spot');
    spot.hidden = !step.spot;
    if (!step.spot) return;
    spot.style.left = step.spot[0] + 'px'; spot.style.top = step.spot[1] + 'px';
    spot.style.width = step.spot[2] + 'px'; spot.style.height = step.spot[3] + 'px';
  }
  /* The frame's size comes from the room left under the tallest caption, in this language, so the window is never cut. */
  function fitStage() {
    var st = document.querySelector('.st'), pin = st.parentElement, box = document.getElementById('caps'), cs = getComputedStyle(pin);
    var tallest = 0;
    /* A caption fills its box, so the box goes to nothing while each is measured by its words. */
    box.style.minHeight = '0';
    caps.forEach(function (c) { tallest = Math.max(tallest, c.scrollHeight); });
    box.style.minHeight = tallest + 'px';
    var marksRoom = parseFloat(getComputedStyle(root).getPropertyValue('--marks-room'));
    var room = pin.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom) - parseFloat(cs.rowGap) - tallest;
    var w = Math.max(0, Math.min(pin.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) - marksRoom, room * WINDOW_RATIO));
    st.style.width = w + 'px'; st.style.height = w / WINDOW_RATIO + 'px';
  }
  function layout() {
    fitStage();
    f0.style.height = (f0.clientWidth / WINDOW_RATIO) + 'px';
    s0.style.transform = 'scale(' + f0.clientWidth / WINDOW_WIDTH + ')';
    place(sw, f1, steps[cur]);
  }

  /* ---------- Scrolling ---------- */
  function onScroll() {
    var st = document.getElementById('story'), b = st.getBoundingClientRect();
    var p = Math.max(0, Math.min(.999, -b.top / (b.height - innerHeight)));
    var n = Math.floor(p * steps.length);
    /* Past steps stay full and the current one fills as it is read. */
    Array.prototype.forEach.call(dots.children, function (d, i) { d.style.setProperty('--fill', Math.max(0, Math.min(1, p * steps.length - i))); });
    if (n === cur) return;
    cur = n; caps.forEach(function (c, i) { c.classList.toggle('on', i === n); });
    place(sw, f1, steps[n]); dim(steps[n]); showLayer(steps[n]);
  }
  /* When scrolling settles between two sections, the page carries on to the next one the way it was going. Judged from where it stopped, with nothing remembered, so a carry that a wheel or a finger interrupted just settles and is judged again.
     Only for a wheel or a finger: a scrollbar being dragged or the keyboard stops exactly where the reader means to. */
  var SETTLE_DELAY = 140;
  var lastY = scrollY, isGoingDown = true, settling, fingers = 0, isCarryWanted = false;
  var reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  var bar = parseFloat(getComputedStyle(root).getPropertyValue('--bar'));
  function settle() {
    if (!isCarryWanted || fingers > 0 || reduceMotion.matches) return;
    var y = scrollY, story = document.getElementById('story').getBoundingClientRect();
    var top = story.top - bar, target = null;
    if (y > 8 && top > 8 && top < innerHeight * 0.8) target = isGoingDown ? y + top : 0;
    else if (story.bottom > bar + 8 && story.bottom < innerHeight - 8) target = isGoingDown ? y + story.bottom - bar : y + story.bottom - innerHeight;
    if (target !== null) window.scrollTo({ top: target, behavior: 'smooth' });
  }
  addEventListener('wheel', function () { isCarryWanted = true; }, { passive: true });
  addEventListener('mousedown', function () { isCarryWanted = false; }, { passive: true });
  addEventListener('keydown', function () { isCarryWanted = false; }, { passive: true });
  addEventListener('scroll', function () {
    var y = scrollY;
    if (y !== lastY) isGoingDown = y > lastY;
    lastY = y;
    clearTimeout(settling);
    settling = setTimeout(settle, SETTLE_DELAY);
  }, { passive: true });
  addEventListener('scroll', onScroll, { passive: true });
  addEventListener('touchstart', function (e) { isCarryWanted = true; fingers = e.touches.length; clearTimeout(settling); }, { passive: true });
  addEventListener('touchend', function (e) { fingers = e.touches.length; clearTimeout(settling); settling = setTimeout(settle, SETTLE_DELAY); }, { passive: true });
  addEventListener('touchcancel', function (e) { fingers = e.touches.length; }, { passive: true });
  /* The logo and every link to the top go to the page's very top, past the sticky bar's offset. */
  document.querySelectorAll('a[href="#top"]').forEach(function (a) {
    a.addEventListener('click', function (e) {
      e.preventDefault();
      /* At once: a smooth trip would play every story step backward on the way. */
      window.scrollTo({ top: 0, behavior: 'instant' });
      /* The address drops any section it named, so a reload stays at the top. */
      history.replaceState(null, '', location.pathname + location.search);
    });
  });

  /* ---------- Start ---------- */
  /* A resize follows the window at once; only a step's move glides. */
  var resizing;
  addEventListener('resize', function () {
    root.classList.add('is-resizing');
    layout();
    /* The story's height follows the window, so the same scroll position can now be a different step. */
    onScroll();
    clearTimeout(resizing);
    resizing = setTimeout(function () { root.classList.remove('is-resizing'); }, 150);
  });
  layout(); dim(steps[0]);
  /* The page was hidden for this: go to the linked part now that the frames have their sizes. */
  var linked = root.classList.contains('is-arriving') && document.getElementById(location.hash.slice(1));
  if (linked) linked.scrollIntoView({ behavior: 'instant' });
  root.classList.remove('is-arriving');
  onScroll();
  function settleFirstLayout() {
    layout();
    /* A timer rather than an animation frame, which a hidden tab never runs. */
    setTimeout(function () { root.classList.remove('is-resizing'); }, 100);
  }
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(settleFirstLayout);
  else settleFirstLayout();
})();
