// Step 4 of the build order in ../../../../README.md: local persistence.
// Mirrors windows/daemon/Storage/FileStore.cs — content-addressed blob
// storage keyed by SHA-256 hex hash. Descriptor-only by design: this class
// never embeds file bytes in any message, matching FilePayload.cs's own
// comment to that effect. Chunked streaming (build order step 10) will
// write/read through this same directory.

import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';

const SUBDIR = 'cliplink_files';

export class FileStore {
  private baseDir: string;

  constructor(context: common.UIAbilityContext) {
    this.baseDir = `${context.filesDir}/${SUBDIR}`;
    if (!fs.accessSync(this.baseDir)) {
      fs.mkdirSync(this.baseDir);
    }
  }

  getPath(hash: string): string {
    return `${this.baseDir}/${hash}`;
  }

  getTempPath(hash: string): string {
    return `${this.baseDir}/${hash}.tmp`;
  }

  exists(hash: string): boolean {
    return fs.accessSync(this.getPath(hash));
  }

  delete(hash: string): void {
    if (this.exists(hash)) {
      fs.unlinkSync(this.getPath(hash));
    }
  }
}
