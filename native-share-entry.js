import { Share } from '@capacitor/share';
import { Filesystem, Directory } from '@capacitor/filesystem';

window.AbsNativeShareReceipt = async function(blob, filename) {
  if (!(blob instanceof Blob)) throw new Error('Receipt image is not available.');
  const dataUrl = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || '').split(',')[1] || '');
    reader.onerror = () => reject(new Error('Could not prepare receipt image for sharing.'));
    reader.readAsDataURL(blob);
  });
  if (!dataUrl) throw new Error('Receipt image conversion returned empty data.');
  const saved = await Filesystem.writeFile({
    path: filename,
    data: dataUrl,
    directory: Directory.Cache,
    recursive: true
  });
  try {
    return await Share.share({
      title: 'ABS KANO LTD receipt',
      text: 'ABS KANO LTD — Sales receipt',
      files: [saved.uri],
      dialogTitle: 'Share receipt'
    });
  } finally {
    try {
      await Filesystem.deleteFile({ path: filename, directory: Directory.Cache });
    } catch (cleanupError) {
      console.warn('Receipt temporary-file cleanup failed:', cleanupError);
    }
  }
};
