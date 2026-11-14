import { parseJob, type Job, type JobPriority } from './jobs';
import {
  asArray,
  asBoolean,
  asCount,
  asNullableString,
  asObject,
  asString,
  fieldPath,
} from './validate';

export interface FolderEntry {
  name: string;
  /** Relative to the root, with forward slashes. */
  path: string;
}

/** Response of `GET /api/v1/browse`: one folder of a root. */
export interface BrowseResult {
  root: string;
  /** Relative to the root; `""` for the root itself. */
  path: string;
  /** The folder above: `""` directly under the root, null for the root itself. */
  parent: string | null;
  /** Sub-folders, sorted by name without regard to case. */
  dirs: FolderEntry[];
  /** Camera raw files directly in this folder. */
  rawFiles: number;
  /** How many of those have their DNG in the cache now. */
  builtFiles: number;
  /** Other files directly in this folder. */
  otherFiles: number;
  /** True when the folder has more than 5000 sub-folders and the list was cut. */
  truncated: boolean;
}

/** The body of `POST /api/v1/folders`. */
export interface FolderRequest {
  root: string;
  path: string;
  /** Also take the files of all sub-folders. */
  recursive: boolean;
  /** Without it the jobs are labelled with the folder's path. */
  label?: string | null;
  /** `normal` when left out. A server older than 0.5 ignores it and builds at normal priority. */
  priority?: JobPriority;
}

/** Response of `POST /api/v1/folders`. */
export interface FolderQueued {
  /** Raw files found. */
  files: number;
  /** How many of them had their DNG already; their items are `ready` at once. */
  alreadyBuilt: number;
  /** One job, or several when there are more files than one job may hold; none for no files. */
  jobs: Job[];
}

/** More raw files than this in one request are refused with `too_many_files`. */
export const MAX_FILES_PER_FOLDER_REQUEST = 50_000;
/** A browse answer lists at most this many sub-folders; `truncated` says it cut the list. */
export const MAX_LISTED_FOLDERS = 5_000;

function parseEntry(value: unknown, path: string): FolderEntry {
  const obj = asObject(value, path);
  return {
    name: asString(obj.name, fieldPath(path, 'name')),
    path: asString(obj.path, fieldPath(path, 'path')),
  };
}

/** Checks the shape of a browse response; throws a ShapeError naming the first bad field. */
export function parseBrowse(data: unknown): BrowseResult {
  const obj = asObject(data, '');
  return {
    root: asString(obj.root, 'root'),
    path: asString(obj.path, 'path'),
    parent: asNullableString(obj.parent, 'parent'),
    dirs: asArray(obj.dirs, 'dirs', parseEntry),
    rawFiles: asCount(obj.rawFiles, 'rawFiles'),
    builtFiles: asCount(obj.builtFiles, 'builtFiles'),
    otherFiles: asCount(obj.otherFiles, 'otherFiles'),
    truncated: asBoolean(obj.truncated, 'truncated'),
  };
}

/** Checks the shape of the answer to queueing a folder. */
export function parseFolderQueued(data: unknown): FolderQueued {
  const obj = asObject(data, '');
  return {
    files: asCount(obj.files, 'files'),
    alreadyBuilt: asCount(obj.alreadyBuilt, 'alreadyBuilt'),
    jobs: asArray(obj.jobs, 'jobs', parseJob),
  };
}
