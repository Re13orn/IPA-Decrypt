// IPA Lab's native bridge. Crypto workers retain their upstream provenance.
import { createAMDGenerator, createSapSigner } from './crypto-api.mjs';
let identity, state, provisioning;
export function initialize(value, saved) { identity = value; state = saved; }
function checked(result) {
  if (result.error || result.status !== 0 || result.nativeStatus !== 0)
    throw new Error('Local device proof failed');
  return result;
}
const amd = () => createAMDGenerator({ ...identity, state, onState: async next => {
  await window.webkit.messageHandlers.nativeStore.postMessage({ operation: 'save', state: next });
  state = next;
} });
export async function invoke(operation, input) {
  if (operation === 'headers') {
    const context = await amd();
    try {
      const result = await context.rpc('otp', { dsid: '-1' });
      if (result.status === -45061) return null;
      checked(result);
      return { 'X-Apple-AMD-M': result.machineIdBase64, 'X-Apple-AMD': result.otpBase64 };
    } finally { context.close(); }
  }
  if (operation === 'start') {
    provisioning?.close();
    provisioning = await amd();
    return checked(await provisioning.rpc('start', { dsid: '-1', spBase64: input }));
  }
  if (operation === 'finish') {
    if (!provisioning) throw new Error('Device proof context expired');
    try { return checked(await provisioning.rpc('finish', input)); }
    finally { provisioning.close(); provisioning = null; }
  }
  if (operation === 'sign') {
    const signer = await createSapSigner(identity.guid, {
      setupURL: 'https://fpinit.itunes.apple.com/v1/signSapSetup',
      fetchImpl: async (url, options = {}) => {
        const data = options.body ? btoa(String.fromCharCode(...options.body)) : null;
        const reply = await window.webkit.messageHandlers.nativeStore.postMessage({
          operation: 'network', url, method: options.method || 'GET', data
        });
        return { ok: reply.status === 200, status: reply.status,
          arrayBuffer: async () => Uint8Array.from(atob(reply.data), c => c.charCodeAt(0)).buffer };
      }
    });
    try { return await signer.sign(input); } finally { await signer.close(); }
  }
  throw new Error('Unknown local operation');
}
