import RFB from './core/rfb.js';
let rfb = null;
let connectionID = null;
let disposed = false;
const screen = document.getElementById('screen');
const setInteraction = (current, enabled) => {
    current.viewOnly = !enabled;
    current.focusOnClick = enabled;
    document.documentElement.classList.toggle('watch-only', !enabled);
    if (!enabled) current.blur();
};
// noVNC's viewOnly suppresses network input, but still handles pointer events and
// renders its cursor locally. Watching must leave the macOS pointer independent
// of that pipeline, including browsers that use a canvas cursor fallback.
for (const type of ['mousemove', 'mouseover', 'mouseleave', 'mousedown', 'mouseup',
                    'click', 'dblclick', 'contextmenu', 'wheel', 'touchstart',
                    'touchmove', 'touchend', 'gesturestart', 'gesturemove', 'gestureend']) {
    screen.addEventListener(type, event => {
        if (rfb && !rfb.viewOnly) return;
        event.stopImmediatePropagation();
        if (event.cancelable) event.preventDefault();
    }, {capture: true, passive: false});
}
const emit = (type, extra = {}) => {
    if (!disposed) window.webkit.messageHandlers.botScreen.postMessage({type, connectionID, ...extra});
};
const dispose = () => {
    disposed = true;
    const old = rfb;
    rfb = null;
    document.documentElement.classList.add('watch-only');
    if (old) { setInteraction(old, false); old.disconnect(); }
    screen.replaceChildren();
};
// WebKit may deliver a native synthesized mousedown with buttons=0 even though
// button identifies the pressed button. noVNC reads buttons rather than button.
// Normalize that inconsistent press only; viewOnly and the server lease still gate input.
screen.addEventListener('mousedown', event => {
    if (!rfb || rfb.viewOnly || event.buttons !== 0) return;
    const mask = [1, 4, 2, 8, 16][event.button];
    if (mask) {
        try { Object.defineProperty(event, 'buttons', {value: mask}); } catch (_) {}
    }
}, true);
window.hermesBotScreen = Object.freeze({
    connect(config) {
        dispose();
        disposed = false;
        connectionID = config.connectionID;
        try {
            const url = new URL(config.websocketURL);
            if (!['ws:', 'wss:'].includes(url.protocol) || url.username || url.password || url.hash) throw new Error();
            const current = new RFB(screen, url.href);
            rfb = current;
            // Input is disabled before the handshake, and remains so until Swift confirms a lease.
            setInteraction(current, false);
            current.scaleViewport = true;
            current.resizeSession = false;
            current.background = '#16181b';
            const active = () => !disposed && rfb === current;
            current.addEventListener('connect', () => { if (active()) emit('connected'); });
            current.addEventListener('disconnect', event => { if (active()) emit('disconnected', {clean: event.detail.clean === true}); });
            current.addEventListener('securityfailure', () => { if (active()) emit('failed'); });
            current.addEventListener('credentialsrequired', () => {
                if (active()) { emit('failed'); dispose(); }
            });
        } catch (_) { emit('failed'); }
    },
    setControl(id, enabled) {
        if (!disposed && rfb && id === connectionID) {
            const wasViewOnly = rfb.viewOnly;
            setInteraction(rfb, enabled === true);
            if (enabled === true && wasViewOnly) rfb.focus();
        }
    },
    dispose
});
window.addEventListener('pagehide', dispose);
window.webkit.messageHandlers.botScreen.postMessage({type: 'ready'});
