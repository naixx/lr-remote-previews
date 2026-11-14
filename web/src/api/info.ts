import {
  asArray,
  asBoolean,
  asCount,
  asInteger,
  asNullableString,
  asObject,
  asOneOf,
  asString,
  fieldPath,
  optional,
} from './validate';

/** The API version this dashboard was written against (`api` in the info response). */
export const CLIENT_API_VERSION = 1;

export const AUTH_MODES = ['token', 'none'] as const;
export type AuthMode = (typeof AUTH_MODES)[number];

export interface ConverterInfo {
  /** Whether Adobe DNG Converter was found on the server. */
  installed: boolean;
  /** Where the server looks for the converter executable. */
  path: string;
  /** Converter version when the server could read it. */
  version: string | null;
}

export interface RootInfo {
  /** Stable identifier used in API paths. */
  id: string;
  /** Human-readable name. */
  label: string;
  /** False when the folder is missing or unreadable on the server right now. */
  available: boolean;
}

export interface Capabilities {
  /** Raw file extensions the server accepts, lower case with a leading dot. */
  extensions: string[];
  /** Long edge of the smart previews the server builds, in pixels. */
  previewLongEdge: number;
  /** The most items one job may have; null from an older server (0.1) that does not send it. */
  maxItemsPerJob: number | null;
  /** Days a job is kept after it left `active`; null from an older server (before 0.3). */
  jobRetentionDays: number | null;
}

/** Response of `GET /api/v1/info`. */
export interface ServerInfo {
  name: string;
  version: string;
  api: number;
  auth: AuthMode;
  converter: ConverterInfo;
  roots: RootInfo[];
  capabilities: Capabilities;
}

function parseConverter(value: unknown, path: string): ConverterInfo {
  const obj = asObject(value, path);
  return {
    installed: asBoolean(obj.installed, fieldPath(path, 'installed')),
    path: asString(obj.path, fieldPath(path, 'path')),
    version: asNullableString(obj.version, fieldPath(path, 'version')),
  };
}

function parseRoot(value: unknown, path: string): RootInfo {
  const obj = asObject(value, path);
  return {
    id: asString(obj.id, fieldPath(path, 'id')),
    label: asString(obj.label, fieldPath(path, 'label')),
    available: asBoolean(obj.available, fieldPath(path, 'available')),
  };
}

function parseCapabilities(value: unknown, path: string): Capabilities {
  const obj = asObject(value, path);
  return {
    extensions: asArray(obj.extensions, fieldPath(path, 'extensions'), asString),
    previewLongEdge: asInteger(obj.previewLongEdge, fieldPath(path, 'previewLongEdge')),
    maxItemsPerJob: optional(obj.maxItemsPerJob, fieldPath(path, 'maxItemsPerJob'), asCount),
    jobRetentionDays: optional(
      obj.jobRetentionDays,
      fieldPath(path, 'jobRetentionDays'),
      asCount,
    ),
  };
}

/** Checks the shape of an info response; throws a ShapeError naming the first bad field. */
export function parseServerInfo(data: unknown): ServerInfo {
  const obj = asObject(data, '');
  return {
    name: asString(obj.name, 'name'),
    version: asString(obj.version, 'version'),
    api: asInteger(obj.api, 'api'),
    auth: asOneOf(obj.auth, 'auth', AUTH_MODES),
    converter: parseConverter(obj.converter, 'converter'),
    roots: asArray(obj.roots, 'roots', parseRoot),
    capabilities: parseCapabilities(obj.capabilities, 'capabilities'),
  };
}
