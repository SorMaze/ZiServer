(function () {
  function initContentLab() {
    var form = document.querySelector('#content-form');
    if (!form) return;

    var format = form.querySelector('#content-format');
    var target = form.querySelector('#content-target');
    var body = form.querySelector('#content-body');
    var send = form.querySelector('#content-send');
    var meta = form.querySelector('#content-meta');
    var dot = form.querySelector('#content-status-dot');
    var output = form.querySelector('#content-output');
    var encoder = new TextEncoder();
    var decoder = new TextDecoder();
    var samples = {
      json: '{"project":"ZiServer","ready":true}',
      xml: '<release><feature>unified-content</feature></release>',
      html: '<article><strong>Rendered as safe response text</strong></article>',
      toml: 'project = "ZiServer"\nready = true\n',
      binary: 'ZiServer binary payload'
    };

    function selectFormat() {
      target.value = '/content/' + format.value;
      body.value = samples[format.value];
      dot.className = 'status-dot';
      meta.textContent = 'Ready · ' + format.options[format.selectedIndex].dataset.mime;
      output.textContent = 'Payload updated. Send it through the shared content middleware.';
    }

    format.addEventListener('change', selectFormat);
    form.addEventListener('submit', async function (event) {
      event.preventDefault();
      var option = format.options[format.selectedIndex];
      var mime = option.dataset.mime;
      var requestBody = format.value === 'binary' ? encoder.encode(body.value) : body.value;
      var requestBytes = format.value === 'binary' ? requestBody.byteLength : encoder.encode(requestBody).byteLength;
      var started = performance.now();
      send.disabled = true;
      dot.className = 'status-dot';
      meta.textContent = 'Sending ' + requestBytes + ' B to ' + target.value + '…';
      output.textContent = '';

      try {
        var response = await fetch(target.value, {
          method: 'POST',
          headers: { 'Content-Type': mime },
          body: requestBody,
          cache: 'no-store'
        });
        var responseBuffer = await response.arrayBuffer();
        var responseBytes = new Uint8Array(responseBuffer);
        var elapsed = Math.round(performance.now() - started);
        var responseType = response.headers.get('content-type') || 'unknown';
        var display;

        if (format.value === 'binary') {
          display = Array.from(responseBytes, function (byte) {
            return byte.toString(16).padStart(2, '0');
          }).join(' ');
          display = 'hex\n' + display + '\n\nutf-8\n' + decoder.decode(responseBytes);
        } else {
          display = decoder.decode(responseBytes);
          if (responseType.indexOf('application/json') === 0) {
            try { display = JSON.stringify(JSON.parse(display), null, 2); } catch (_) {}
          }
        }

        dot.className = 'status-dot ' + (response.ok ? 'ok' : 'error');
        meta.textContent = response.status + ' · ' + responseType + ' · ' + responseBytes.byteLength + ' B · ' + elapsed + ' ms';
        output.textContent = display || '(empty response)';
      } catch (error) {
        dot.className = 'status-dot error';
        meta.textContent = 'Request failed';
        output.textContent = error.name + ': ' + error.message;
      } finally {
        send.disabled = false;
      }
    });
  }

  document.addEventListener('DOMContentLoaded', initContentLab);

  if (typeof gsap === 'undefined' || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    document.addEventListener('DOMContentLoaded', function () {
      document.documentElement.style.visibility = 'visible';
    });
    return;
  }

  if (typeof ScrollTrigger !== 'undefined') {
    gsap.registerPlugin(ScrollTrigger);
  }

  var EASE = 'power3.out';

  function initStaticPage() {
    if (document.querySelector('header')) return;
    var main = document.querySelector('main');
    if (!main) return;

    var eyebrow = main.querySelector('.eyebrow');
    var h1 = main.querySelector('h1');
    var bodyP = main.querySelector('p:not(.eyebrow):not(.links)');
    var links = main.querySelectorAll('.links a');

    if (eyebrow) gsap.set(eyebrow, { opacity: 0, y: 24 });
    if (h1) gsap.set(h1, { opacity: 0, y: 20 });
    if (bodyP) gsap.set(bodyP, { opacity: 0, y: 16 });
    gsap.set(links, { opacity: 0, y: 12, scale: .96 });

    document.documentElement.style.visibility = 'visible';

    var tl = gsap.timeline({ defaults: { ease: EASE } });
    if (eyebrow) tl.to(eyebrow, { opacity: 1, y: 0, duration: .55 });
    if (h1) tl.to(h1, { opacity: 1, y: 0, duration: .6 }, '-=0.25');
    if (bodyP) tl.to(bodyP, { opacity: 1, y: 0, duration: .5 }, '-=0.25');
    if (links.length) {
      tl.to(links, { opacity: 1, y: 0, scale: 1, duration: .4, stagger: .08 }, '-=0.15');
    }
  }

  function initDynamicPage() {
    var header = document.querySelector('header');
    if (!header) return;
    var heroSection = document.querySelector('main > section');
    var visual = document.querySelector('.visual');
    var bandCards = document.querySelectorAll('.band .item');
    var updateCards = document.querySelectorAll('.update-card');
    var playground = document.querySelector('.playground');

    if (header) gsap.set(header, { opacity: 0, y: -30 });

    if (heroSection) {
      var eyebrow = heroSection.querySelector('.eyebrow');
      var h1 = heroSection.querySelector('h1');
      var bodyP = heroSection.querySelector('p:not(.eyebrow)');
      var actions = heroSection.querySelectorAll('.actions a');

      if (eyebrow) gsap.set(eyebrow, { opacity: 0, y: 24 });
      if (h1) gsap.set(h1, { opacity: 0, y: 20 });
      if (bodyP) gsap.set(bodyP, { opacity: 0, y: 16 });
      gsap.set(actions, { opacity: 0, y: 12, scale: .96 });
    }

    if (visual) gsap.set(visual, { opacity: 0, x: 40, scale: .97 });
    if (bandCards.length) gsap.set(bandCards, { opacity: 0, y: 36, scale: .96 });
    if (updateCards.length) gsap.set(updateCards, { opacity: 0, y: 28 });
    if (playground) gsap.set(playground, { opacity: 0, y: 32 });

    document.documentElement.style.visibility = 'visible';

    var tl = gsap.timeline({ defaults: { ease: EASE } });

    if (header) {
      tl.to(header, { opacity: 1, y: 0, duration: .55 });
    }

    if (heroSection) {
      var eyebrow2 = heroSection.querySelector('.eyebrow');
      var h1_2 = heroSection.querySelector('h1');
      var bodyP2 = heroSection.querySelector('p:not(.eyebrow)');
      var actions2 = heroSection.querySelectorAll('.actions a');

      if (eyebrow2) tl.to(eyebrow2, { opacity: 1, y: 0, duration: .5 }, '-=0.2');
      if (h1_2) tl.to(h1_2, { opacity: 1, y: 0, duration: .6 }, '-=0.25');
      if (bodyP2) tl.to(bodyP2, { opacity: 1, y: 0, duration: .5 }, '-=0.3');
      if (actions2.length) {
        tl.to(actions2, { opacity: 1, y: 0, scale: 1, duration: .4, stagger: .08 }, '-=0.15');
      }
    }

    if (visual) {
      tl.to(visual, { opacity: 1, x: 0, scale: 1, duration: .6, ease: 'power2.out' }, '-=0.4');

      var codeBlock = visual.querySelector('.code');
      if (codeBlock) {
        gsap.fromTo(codeBlock, { boxShadow: '0 0 0 0 rgba(47,122,138,.5)' }, {
          boxShadow: '0 0 0 0 rgba(47,122,138,0)',
          duration: 1.2,
          delay: .8,
          ease: 'power2.out'
        });
      }
    }

    if (bandCards.length) {
      gsap.to(bandCards, {
        opacity: 1, y: 0, scale: 1,
        duration: .55,
        stagger: .12,
        ease: EASE,
        scrollTrigger: {
          trigger: '.band',
          start: 'top 85%',
          toggleActions: 'play none none none'
        }
      });
    }

    if (updateCards.length) {
      gsap.to(updateCards, {
        opacity: 1, y: 0,
        duration: .5,
        stagger: .08,
        ease: EASE,
        scrollTrigger: {
          trigger: '.updates',
          start: 'top 86%',
          toggleActions: 'play none none none'
        }
      });
    }

    if (playground) {
      gsap.to(playground, {
        opacity: 1, y: 0,
        duration: .65,
        ease: EASE,
        scrollTrigger: {
          trigger: playground,
          start: 'top 88%',
          toggleActions: 'play none none none'
        }
      });
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    initStaticPage();
    initDynamicPage();
  });
})();
