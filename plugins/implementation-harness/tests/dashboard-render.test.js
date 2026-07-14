// dashboard-render.test.js — regression guard that the dashboard's CLIENT-SIDE render actually RUNS.
//
// WHY THIS EXISTS: the dashboard renders the task list in the browser (the big inline <script> in
// server.js's renderPage()). A server-side unit test of a helper can pass while the browser render is
// broken — which is exactly what happened at 1.76.0: `pillsFor` (client) called `modelProgression`,
// which is defined only in lib.js (server-side, `require`d), so every task list threw a ReferenceError
// and came up BLANK, while the server-rendered shell + summary cards still showed. lib.test.js tested
// modelProgression server-side and passed. Nothing executed the client render → the break shipped.
//
// This test extracts the RESOLVED client script from renderPage(), runs it in a minimal browser stub
// (vm + a fake document/window/fetch), then calls the real render functions against representative
// backlog data covering every bucket + the completedWith badge path. A client-side ReferenceError (a
// server-only function called in the browser, an undefined helper, a bad template) fails it loudly.
'use strict';
const assert = require('assert');
const vm = require('vm');
const path = require('path');
const { renderPage } = require(path.join(__dirname, '../templates/dashboard/server.js'));

let pass = 0, fail = 0;
function test(name, fn) { try { fn(); pass++; console.log('ok - ' + name); }
  catch (e) { fail++; console.error('FAIL - ' + name + '\n       ' + (e && e.message)); } }

// --- extract the resolved client script (the ${...} interpolations are already evaluated) ---
const html = renderPage();
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x => x[1]);
const clientJs = scripts.find(s => /function\s+renderBacklog\b/.test(s));
assert(clientJs, 'renderPage() must contain the client app <script> (with renderBacklog)');

// --- minimal browser stub (no jsdom — stays within the dashboard's zero-dependency philosophy) ---
const els = {};
function stubEl() {
  return { innerHTML: '', textContent: '', value: '', checked: false, style: {}, dataset: {},
    classList: { add(){}, remove(){}, toggle(){}, contains(){ return false; } },
    addEventListener(){}, removeEventListener(){}, appendChild(){}, removeChild(){}, insertBefore(){},
    setAttribute(){}, removeAttribute(){}, getAttribute(){ return null; }, hasAttribute(){ return false; },
    closest(){ return null; }, matches(){ return false; }, querySelector(){ return null; },
    querySelectorAll(){ return []; }, getBoundingClientRect(){ return { left:0, top:0, right:0, bottom:0, width:0, height:0 }; },
    scrollIntoView(){}, focus(){}, blur(){}, remove(){}, click(){}, children: [], parentNode: null, firstChild: null };
}
const documentStub = {
  getElementById(id){ return els[id] || (els[id] = stubEl()); },
  createElement(){ return stubEl(); }, createTextNode(){ return stubEl(); },
  querySelector(){ return null; }, querySelectorAll(){ return []; },
  addEventListener(){}, removeEventListener(){}, body: stubEl(), documentElement: stubEl(),
  title: '', getElementsByClassName(){ return []; } };
const sandbox = {
  document: documentStub,
  fetch(){ return Promise.reject(new Error('no network in test')); },   // refreshBacklog etc. catch + return
  setInterval(){ return 0; }, clearInterval(){}, setTimeout(){ return 0; }, clearTimeout(){},
  requestAnimationFrame(){ return 0; }, cancelAnimationFrame(){},
  console, JSON, Math, Date, Object, Array, String, Number, Boolean, RegExp, Set, Map, WeakMap,
  Promise, parseInt, parseFloat, isNaN, isFinite, encodeURIComponent, decodeURIComponent, escape, unescape, Error,
  localStorage: { getItem(){ return null; }, setItem(){}, removeItem(){} },
  navigator: { clipboard: { writeText(){ return Promise.resolve(); } } },
  location: { href: '', reload(){}, hostname: '127.0.0.1' },
};
sandbox.window = sandbox; sandbox.self = sandbox; sandbox.globalThis = sandbox;
sandbox.window.innerWidth = 1200; sandbox.window.innerHeight = 800;
sandbox.window.matchMedia = function(){ return { matches: false, addEventListener(){}, removeEventListener(){} }; };
sandbox.window.addEventListener = function(){};
sandbox.EventSource = function(){ return { addEventListener(){}, close(){}, onmessage: null, onerror: null }; };

const ctx = vm.createContext(sandbox);

test('the client <script> loads + runs its bootstrap without throwing (defines the render fns)', () => {
  vm.runInContext(clientJs, ctx, { filename: 'dashboard-client.js' });
  assert.strictEqual(typeof sandbox.renderBacklog, 'function', 'renderBacklog must be defined client-side');
  assert.strictEqual(typeof sandbox.pillsFor, 'function', 'pillsFor must be defined client-side');
});

// representative data: every bucket + the done/donePendingReview/closedFailed badge path that broke.
const DATA = {
  counts: { ready:1, waiting:1, needsHuman:1, failedPendingReview:1, donePendingReview:2, done:2, closedFailed:1 },
  buckets: {
    ready:  [{ id:'T001', title:'ready',   status:'pending' }],
    waiting:[{ id:'T002', title:'waiting', status:'pending', waitingOn:['T001'] }],
    needsHuman:[{ id:'T003', title:'gate',  status:'pending', gate:'needs-human' }],
    failedPendingReview:[{ id:'T004', title:'failed', status:'failed', failed:true, reviewed:false, buildFailures:{ count:2 } }],
    donePendingReview:[
      // the exact shape that triggered the 1.76.0 ReferenceError: a done task WITH completedWith, escalated.
      { id:'T005', title:'escalated', status:'done', failed:false, reviewed:false,
        completedWith:{ model:'claude-sonnet-5', effort:'high', startModel:'claude-haiku-4-5', startEffort:null,
                        progression:{ start:'claude-haiku-4-5', end:'claude-sonnet-5/high', escalated:true } } },
      { id:'T006', title:'human', status:'done', failed:false, reviewed:false, completedWith:{ human:true } },
    ],
    done:[
      { id:'T007', title:'first-try', status:'done', failed:false, reviewed:true,
        completedWith:{ model:'claude-haiku-4-5', effort:null, startModel:'claude-haiku-4-5', startEffort:null,
                        progression:{ start:'claude-haiku-4-5', end:'claude-haiku-4-5', escalated:false } } },
      // old outcome data WITHOUT a progression field — must not crash (backward-compat).
      { id:'T008', title:'legacy', status:'done', failed:false, reviewed:true, completedWith:{ model:'claude-sonnet-5', effort:'low' } },
    ],
    closedFailed:[{ id:'T009', title:'closed', status:'failed', failed:true, reviewed:true }],
  },
};

test('renderBacklog renders EVERY bucket without throwing + populates #sections', () => {
  assert.doesNotThrow(() => sandbox.renderBacklog(DATA),
    'renderBacklog threw — a client-side error blanks the whole task list (this is the 1.76.0 regression)');
  const sections = els['sections'].innerHTML;
  assert(sections && sections.length > 50, '#sections must be populated with the rendered task list');
  for (const id of ['T001','T002','T003','T004','T005','T006','T007','T008','T009']) {
    assert(sections.includes(id), 'rendered task list must include ' + id + ' (bucket render is complete)');
  }
});

test('the escalated completedWith badge shows start → end (the feature works, not just non-crash)', () => {
  const sections = els['sections'].innerHTML;
  assert(sections.includes('claude-haiku-4-5') && sections.includes('claude-sonnet-5/high'),
    'the escalated badge must render both the start and end model');
});

// belt-and-suspenders static guard: no lib.js SERVER-ONLY export may be CALLED in the client script
// unless it is also DEFINED there — this is exactly how modelProgression slipped in.
test('no server-only lib.js export is called in the client script (the root-cause class)', () => {
  const libExports = ['computeBacklog','parseJsonl','coldTierIndex','harnessCells','recentActivity',
    'failureKinds','ideasFromJsonl','liveOutputFromJsonl','modelProgression'];
  for (const fn of libExports) {
    const called  = new RegExp('[^.\\w]' + fn + '\\s*\\(').test(clientJs);
    const defined = new RegExp('function\\s+' + fn + '\\b|(?:const|let|var)\\s+' + fn + '\\s*=').test(clientJs);
    assert(!(called && !defined), 'client script calls server-only lib export `' + fn +
      '` but does not define it — it will ReferenceError in the browser (compute it server-side + attach to the task instead)');
  }
});

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
