(function () {
  // Try every account index of this Chrome profile; keep the feed whose title
  // names the wanted mailbox (exact email, or any mailbox on the domain when no
  // email is configured). Gmail's Trusted Types CSP forbids DOMParser, so
  // everything is regex over the raw XML.
  var email = (window.__fcEmail || '').toLowerCase();
  var domain = (window.__fcDomain || '').toLowerCase();
  function wanted(addr) {
    addr = addr.trim().toLowerCase();
    if (email) return addr === email;
    return domain ? addr.slice(-(domain.length + 1)) === '@' + domain : true;
  }
  window.__fcFeed = 'pending';
  var idx = [0, 1, 2, 3, 4, 5];
  Promise.all(idx.map(function (i) {
    return fetch('https://mail.google.com/mail/u/' + i + '/feed/atom', { credentials: 'include', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.text() : ''; })
      .catch(function () { return ''; });
  })).then(function (txts) {
    for (var i = 0; i < txts.length; i++) {
      var m = txts[i].match(/<title>Gmail - Inbox for ([^<]*)<\/title>/);
      if (m && wanted(m[1])) { window.__fcFeed = txts[i]; return; }
    }
    window.__fcFeed = 'ERR:no login for ' + (email || '@' + domain) + ' in this Chrome profile';
  }).catch(function (e) { window.__fcFeed = 'ERR:' + e; });
  return 'started';
})()
