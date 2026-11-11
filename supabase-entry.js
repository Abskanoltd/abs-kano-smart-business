import { createClient } from '@supabase/supabase-js';
import { Share } from '@capacitor/share';
import { Filesystem, Directory } from '@capacitor/filesystem';

// Preserve the existing app's window.supabase.createClient interface.
window.supabase = { createClient };

// Native Android receipt sharing: write the generated PNG to app cache and share its file URI.
window.nativeShareReceipt = async ({ dataUrl, filename }) => {
  const base64 = String(dataUrl).split(',')[1];
  if (!base64) throw new Error('Receipt image data is empty');
  const saved = await Filesystem.writeFile({ path: filename, data: base64, directory: Directory.Cache });
  return Share.share({ title: 'Sale receipt', text: 'ABS KANO LTD receipt', url: saved.uri, dialogTitle: 'Share receipt' });
};
