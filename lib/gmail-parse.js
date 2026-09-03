(function () {
  // No DOMParser: Gmail's Trusted Types policy blocks it. Plain regex over the XML.
  var t = window.__fcFeed;
  if (!t || t === 'pending') return 'pending';
  if (t.indexOf('ERR:') === 0) return t;
  var since = window.__fcSince || '';
  var after = window.__fcAfter || '';   // issued time of the last code we used
  var best = null;
  var entries = t.split('<entry>').slice(1);
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i];
    var tm = e.match(/<title>([\s\S]*?)<\/title>/);
    var im = e.match(/<issued>([^<]*)<\/issued>/);
    var m = tm && tm[1].match(/AuthCode:\s*(\d{4,8})/i);
    if (!m) continue;
    var issued = im ? im[1] : '';
    if (issued < since || issued <= after) continue;
    if (!best || issued > best.issued) best = { code: m[1], issued: issued };
  }
  return best ? best.code + '|' + best.issued : 'none';
})()
