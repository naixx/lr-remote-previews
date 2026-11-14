/**
 * Plain-language explanations of the error codes the protocol defines. The server's `detail` or
 * `message` is shown next to them, so a code missing here still reaches the person.
 */

const ITEM_ERRORS: Record<string, string> = {
  // Rejected: nothing was tried.
  unknown_root: 'The root is not configured on the server.',
  root_unavailable: 'The root is not available on the server, for example an unmounted volume.',
  bad_path: 'The path is not acceptable.',
  unsupported_format: 'Not a camera raw format the server accepts.',
  not_found: 'The file was not found, or the server may not read it.',
  not_a_file: 'The path is not a file.',
  // Failed: the server tried.
  converter_failed: 'The converter could not convert the file.',
  converter_timeout: 'The converter took too long and was stopped.',
  output_missing: 'The converter wrote no DNG.',
  output_mismatch: 'The DNG does not name this file as its original.',
  source_changed: 'The file changed or vanished between the request and the build.',
};

/** What an item error code means, or null for a code this dashboard does not know. */
export function explainItemError(code: string): string | null {
  return ITEM_ERRORS[code] ?? null;
}

const FOLDER_ERRORS: Record<string, { title: string; text: string }> = {
  unknown_root: {
    title: 'Unknown root',
    text: 'The server has no root with this id. It may have been renamed or removed from its configuration.',
  },
  root_unavailable: {
    title: 'Root not available',
    text: 'The server cannot reach this root right now, for example because the volume is not mounted.',
  },
  not_found: {
    title: 'Folder not found',
    text: 'This folder does not exist on the server, or it was moved or renamed.',
  },
  bad_path: {
    title: 'Path not acceptable',
    text: 'The server refused this path.',
  },
  not_a_folder: {
    title: 'Not a folder',
    text: 'This path names a file, not a folder.',
  },
  too_many_files: {
    title: 'Too many files',
    text: 'More than 50,000 raw files were found. Queue the sub-folders one at a time instead.',
  },
  converter_not_installed: {
    title: 'Converter not installed',
    text: 'Adobe DNG Converter is not installed on the server, so files without a DNG cannot be built. The Converter page says where the server expects it.',
  },
};

/** Title and explanation for an error of browsing or queueing a folder; null if unknown. */
export function explainFolderError(code: string | null): { title: string; text: string } | null {
  return code === null ? null : (FOLDER_ERRORS[code] ?? null);
}
