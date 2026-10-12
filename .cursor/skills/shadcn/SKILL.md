---
name: shadcn
description: Project-aware shadcn/ui workflow for searching, adding, composing, and fixing components. Use when the project has shadcn/ui or the user asks to add, compose, or fix shadcn components.
---

# shadcn/ui

Components are source in the project via the CLI. Use the project's package runner (`npx`, `pnpm dlx`, or `bunx --bun`) with `shadcn@latest`.

This skill applies **only** when the repo uses shadcn (has `components.json`) or the user explicitly asks for it.

## Principles

1. Use existing components first. Search registries before writing custom UI.
2. Compose: settings = Tabs + Card + fields; dashboard = Sidebar + Card + Chart + Table.
3. Built-in variants before custom styles.
4. Semantic colors (`bg-primary`, `text-muted-foreground`) — never raw `bg-blue-500`.

## Critical rules

- `className` for layout, not recoloring component internals
- No `space-x-*` / `space-y-*` — `flex` + `gap-*`
- Equal sides: `size-*`, not `w-10 h-10`
- `truncate` shorthand
- No manual `dark:` color overrides
- `cn()` for conditional classes
- No manual `z-index` on Dialog/Sheet/Popover
- Forms: `FieldGroup` + `Field`, not raw labeled div stacks
- `SelectItem` lives in `SelectGroup`; same for dropdown/command items
- Dialog/Sheet/Drawer always have a Title (`sr-only` if hidden)
- Full Card composition (Header/Title/Description/Content/Footer)
- Button loading: `Spinner` + `disabled`, no `isLoading` prop
- `Avatar` always has `AvatarFallback`
- Icons: `data-icon="inline-start|inline-end"`, no size classes on icons inside components
- Registry must be explicit — ask which registry if the user does not name one

## Workflow

1. `npx shadcn@latest info --json` for aliases, base (radix vs base), icon library, Tailwind version
2. Check installed components before `add`
3. `search` → `docs <name>` → fetch those URLs → `add`
4. After add, read the files, fix imports/aliases, swap icons to the project library
5. Updates: `--dry-run` and `--diff`; never `--overwrite` without approval

## Quick map

| Need | Use |
| --- | --- |
| Action | `Button` |
| Fields | `Input`, `Select`, `Combobox`, `Switch`, `Checkbox`, `Field` |
| 2–5 options | `ToggleGroup` |
| Overlay | `Dialog` / `Sheet` / `Drawer` / `AlertDialog` |
| Feedback | `sonner` or project toast, `Alert`, `Skeleton`, `Spinner` |
| Empty | `Empty` |
| Chat | `MessageScroller`, `Message`, `Bubble` |
