const status = document.getElementById('status');
const ready = document.getElementById('ready');
const help = document.getElementById('help');
const download = document.getElementById('download');
const sessionId = new URLSearchParams(window.location.search).get('session_id');

async function checkPurchase() {
  if (!sessionId || !/^cs_(?:test|live)_[A-Za-z0-9]{10,}$/.test(sessionId)) {
    status.textContent = 'No valid checkout session was found.';
    help.hidden = false;
    return;
  }

  try {
    const response = await fetch(`/api/status?session_id=${encodeURIComponent(sessionId)}`, {
      cache: 'no-store',
      credentials: 'omit',
    });
    const result = await response.json();
    if (!response.ok || result.paid !== true) {
      status.textContent = 'We could not confirm payment yet.';
      help.hidden = false;
      return;
    }
    download.href = `/api/download?session_id=${encodeURIComponent(sessionId)}`;
    ready.hidden = false;
    status.textContent = 'Payment confirmed. Your Mac download is ready.';
  } catch {
    status.textContent = 'We could not check your payment right now.';
    help.hidden = false;
  }
}

checkPurchase();
