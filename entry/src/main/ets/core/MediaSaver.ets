/**
 * 媒体保存到用户目录（M3-media）：TDLib 沙盒文件 → DocumentViewPicker 系统保存对话框。
 *
 * 方案（API 26 核对）：picker.DocumentViewPicker.save(DocumentSaveOptions) 返回用户选定/预建的
 * 目标 URI（docs/storage 用户文件域，非应用沙盒）；fs.openSync(URI, READ_WRITE) 取 fd 后
 * fs.copyFile(沙盒路径, fd) 完成落盘。系统对话框本身就是"保存到用户目录"的授权闭环，
 * 无需申请用户目录写权限（picker 免授权特性）。
 *
 * 返回：'saved' / 'cancelled'（用户取消）/ 'failed'。
 * 日志红线：不记路径/文件名，仅记结果。
 */
import { picker, fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'MediaSaver';
const LOG_DOMAIN: number = 0x0012;

export class SaveResult {
  static readonly SAVED: string = 'saved';
  static readonly CANCELLED: string = 'cancelled';
  static readonly FAILED: string = 'failed';
}

export class MediaSaver {
  /**
   * 保存文档到用户目录（系统保存对话框）。
   * @param context UIAbility 上下文（picker 挂载窗口用）
   * @param srcPath TDLib 沙盒内源文件绝对路径
   * @param fileName 建议保存文件名
   */
  static saveDocument(context: common.UIAbilityContext, srcPath: string, fileName: string): Promise<string> {
    return MediaSaver.saveDocumentInner(context, srcPath, fileName);
  }

  private static async saveDocumentInner(context: common.UIAbilityContext,
    srcPath: string, fileName: string): Promise<string> {
    const safeName: string = fileName.length > 0 ? fileName : 'file';
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [safeName];
    const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    let uris: Array<string>;
    try {
      uris = await docPicker.save(saveOptions);
    } catch (err) {
      hilog.warn(LOG_DOMAIN, TAG, 'picker.save rejected: %{private}s', JSON.stringify(err));
      return SaveResult.FAILED;
    }
    if (uris === undefined || uris.length === 0) {
      return SaveResult.CANCELLED;
    }
    let dest: fileIo.File | null = null;
    try {
      dest = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE);
      await fileIo.copyFile(srcPath, dest.fd);
      hilog.info(LOG_DOMAIN, TAG, 'document saved to user dir');
      return SaveResult.SAVED;
    } catch (err) {
      hilog.warn(LOG_DOMAIN, TAG, 'copy failed: %{private}s', JSON.stringify(err));
      return SaveResult.FAILED;
    } finally {
      if (dest !== null) {
        fileIo.closeSync(dest);
      }
    }
  }
}
