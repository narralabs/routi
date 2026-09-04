import { z } from 'zod'

/**
 * A message is an ordered array of blocks, never a plain string.
 *
 * This is the single most load-bearing decision in the schema. The UI interleaves
 * prose, inline screenshots, and tool cards ("Computer — Done") within one assistant
 * turn; a string field would force a migration the moment tools land in M4.
 */

export const TextBlock = z.object({
  type: z.literal('text'),
  text: z.string(),
})

export const ThinkingBlock = z.object({
  type: z.literal('thinking'),
  text: z.string(),
})

export const ImageBlock = z.object({
  type: z.literal('image'),
  mediaType: z.string(),
  /** Small images inline; larger ones are fetched from the daemon by `assetId`. */
  dataUrl: z.string().optional(),
  assetId: z.string().optional(),
  width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(),
})

/** Renders as a tool card in the transcript. */
export const ToolUseBlock = z.object({
  type: z.literal('tool_use'),
  id: z.string(),
  name: z.string(),
  /** Human-readable one-liner for the card header, e.g. "Sign in to your Kalshi account". */
  title: z.string().optional(),
  input: z.unknown().optional(),
  status: z.enum(['running', 'done', 'error']),
})

export const ToolResultBlock = z.object({
  type: z.literal('tool_result'),
  toolUseId: z.string(),
  isError: z.boolean().optional(),
  /** Text and image results; nested tool blocks are not permitted. */
  content: z.array(z.union([TextBlock, ImageBlock])).default([]),
})

/** Emitted when a bot starts, stops, or acts on a surface. */
export const SurfaceEventBlock = z.object({
  type: z.literal('surface_event'),
  sessionId: z.string(),
  kind: z.enum(['attached', 'detached', 'screenshot']),
  assetId: z.string().optional(),
})

export const Block = z.discriminatedUnion('type', [
  TextBlock,
  ThinkingBlock,
  ImageBlock,
  ToolUseBlock,
  ToolResultBlock,
  SurfaceEventBlock,
])

export type TextBlock = z.infer<typeof TextBlock>
export type ThinkingBlock = z.infer<typeof ThinkingBlock>
export type ImageBlock = z.infer<typeof ImageBlock>
export type ToolUseBlock = z.infer<typeof ToolUseBlock>
export type ToolResultBlock = z.infer<typeof ToolResultBlock>
export type SurfaceEventBlock = z.infer<typeof SurfaceEventBlock>
export type Block = z.infer<typeof Block>
