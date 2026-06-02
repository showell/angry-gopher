/* LearnFakeHost — one global fetch interceptor for /learn demos.

   Lessons that need to simulate server responses register routes here
   instead of monkey-patching window.fetch themselves. The host owns
   the wrap, the dispatch, and the fall-through to the real fetch for
   any URL no route claims.

   Pattern moved out of individual lesson demos for two reasons:
     1) Onion-wrap fragility. Each lesson used to do
        `var orig = fetch; fetch = function(...){ ... return orig(...) }`,
        which chained correctly only because Lesson 7's `orig` happened
        to be Lesson 6's wrapper. One mis-ordered script tag would
        silently break the chain.
     2) Repetition. Five lines of wrap boilerplate per lesson, when
        what's actually distinct is the URL pattern and the response.

   API:
     LearnFakeHost.register({match, respond})
       match:    string | RegExp | function(url) → bool|RegExpMatchArray
                 - string: matched literally (url === match) OR as
                   a prefix (url.startsWith(match)). Lesson 8's
                   '/chat/c/lesson8-fake/new' style — convenient
                   when there's just one path.
                 - RegExp: url.match(re); the captured groups land
                   on ctx.match for the responder to use.
                 - function: any custom predicate; truthy return
                   selects this route.
       respond:  function(ctx) → Promise<ResponseShape>
                 ctx = { url, opts, match }. ResponseShape is a
                 plain object with the fields the caller will read:
                 typically { ok, json?(), text?() }.

   Routes are tried in registration order; the first match wins.
   A URL no route claims falls through to the original window.fetch. */
window.LearnFakeHost = (function(){
  'use strict';

  var routes = [];
  var origFetch = window.fetch;

  // lint:called-once dispatch-helper — invoked per route on every fetch
  function tryMatch(spec, url){
    if(typeof spec === 'string'){
      if(url === spec) return true;
      if(url.indexOf(spec) === 0) return true;
      return null;
    }
    if(spec instanceof RegExp) return url.match(spec);
    if(typeof spec === 'function') return spec(url);
    return null;
  }

  window.fetch = function(url, opts){
    if(typeof url === 'string'){
      for(var i = 0; i < routes.length; i++){
        var match = tryMatch(routes[i].match, url);
        if(match){
          return routes[i].respond({url: url, opts: opts || {}, match: match});
        }
      }
    }
    return origFetch.apply(this, arguments);
  };

  function register(route){ routes.push(route); }

  return { register: register };
})();
