# Analysis JSON export

The **Export Analysis JSON** button in the **Import/Export Build** tab writes a
machine-readable snapshot of the current Path of Building build and its current
calculation output. It is intended for local analysis, auditing, and tooling. It
does not upload data or replace the normal Path of Building build-code export.

## Output location

Exports are written automatically to the `Exports/` directory beneath Path of
Building's user-data directory. The filename has this form:

```text
pob_analysis_<sanitized-build-name>_<YYYYMMDD-HHMMSS>.json
```

An export never replaces an existing file. If the timestamped name already
exists, Path of Building appends `_2`, `_3`, and so on before `.json`. The JSON
document is encoded first, written to a temporary file in `Exports/`, closed,
and atomically renamed into place. A failed encode, write, close, or rename
therefore cannot leave a partially written final export.

Path of Building shows the complete path after a successful export. If the
build is waiting to be recalculated, or the current calculation environment is
not available, the export stops with an error instead of writing stale cached
values.

## Schema

The schema identifier is `pob-analysis-export-v1`. Version 1 contains:

- `metadata`: export time, Path of Building and target versions, build source,
  and active set/tree/loadout information where available.
- `character`: level, class, ascendancies, and the current bandit and Pantheon
  choices.
- `active_context`: the main-output skill context, selected calculation-detail
  mode, active skill-specific settings, and Full DPS state.
- `equipment`: equipped slots, canonical item text, sockets, and references to
  socketed skill groups.
- `skill_groups`: active-set groups and their gems, selection, source, and
  Full DPS information.
- `passive_tree`: allocated passive and ascendancy nodes, masteries, jewels,
  represented node modifications such as tattoos, their stat lines, and
  deterministic tattoo type/count data.
- `configuration.input`: primitive values from the active configuration input
  table.
- `configuration.placeholder`: primitive values from the active configuration
  placeholder table.
- `configuration.effective`: the option values selected by the Configuration
  tab's typed input/placeholder resolution.
- `configuration.effective_enemy_level`: the already-resolved enemy level.
- `calculations.summary`: stable names for commonly used current outputs.
- `calculations.scalar_outputs`: every primitive value from the authoritative
  current `mainOutput` table.
- `export_warnings`: normalization or omission notices.

Object keys are emitted in deterministic order and the document is pretty
printed. Arrays whose order is meaningful, such as skill groups and gems, use
Path of Building's displayed order.

## Build facts and configuration

The character section uses the current character choices from
`configTab.input`. In particular, `character.bandit`,
`character.pantheon_major_god`, and `character.pantheon_minor_god` reflect the
values that Path of Building currently uses for calculations and writes when
saving. The legacy build fields are used only as a fallback when a current
configuration value is unavailable.

The configuration section is separate. Its `input` and `placeholder` objects
preserve the active primitive values, including manual assumptions such as
enemy state, charges, ailments, flask state, overlap counts, and custom
modifier text. Configuration keys for bandit or Pantheon may therefore also be
present; the corresponding character fields expose those current choices in a
stable schema.

Active skill-specific UI state is separate from ConfigTab configuration.
`active_context.active_skill_settings` is authoritative for the selected
skill's primitive settings, including its part, mode, stage count, mine count,
minion, minion skill, and minion item set when present. For example, a Winter
Orb stage selection is exported as `skill_stage_count`. The compatibility
fields `selected_skill_part` and `selected_skill_mode` may repeat two of these
values.

`effective` is not a generic merge. It uses each option's type from PoB's
Configuration option registry and follows `ConfigTab:BuildModList`:

- A true `check` input resolves to `true`; false or absent checks are omitted.
- For `count`, `integer`, and `float`, a non-zero input wins. Otherwise a
  non-zero placeholder is used.
- For `countAllowZero`, an explicit input wins even when it is zero. If input
  is absent, a placeholder wins even when it is zero.
- `list` and `text` use supplied input only; their placeholders are not applied
  by `BuildModList`.

Unknown configuration variables remain available in `input` and `placeholder`,
but are omitted from `effective` because their type semantics are not known.
The export adds one warning identifying those omissions.

Path of Building does not track whether each field was imported, entered
manually, or subsequently edited. The export preserves the current build state,
not provenance.

## Intentional omissions and normalization

The export selects documented fields instead of serializing internal objects.
It intentionally omits UI controls, functions, userdata, modifier databases,
tooltips, calculation caches, breakdown tables, and cyclic object graphs.
Canonical raw item text is retained so downstream tools can audit or parse
items without depending on Path of Building's internal modifier objects.
Passive node modifications retain selected stable identifiers and primitive
stat lines, but do not contain full passive node objects.

Only top-level string, number, and boolean calculation outputs are copied.
NaN and positive or negative infinity are encoded as JSON `null` and produce an
export warning. Other complex calculation outputs are omitted with a concise
warning. Exporting does not recalculate mechanics, change configuration, or
mark the build modified.

PoB's loadout UI derives ordinary loadouts from coincidentally equal set
titles, without storing an authoritative loadout object. The exporter does not
repeat that guess. Active loadout fields are emitted only when PoB's exact
special-link maps connect the active passive tree, item set, skill set, and
configuration set. In that case, `active_loadout_link_id` is the authoritative
special-link identifier and `active_loadout_name` is the matched tree set's
loadout name; no loadout index is exported. The independently reliable
active-set fields are always retained when available.

## Compatibility

Consumers should select behavior using the top-level `schema` value. Additive
fields may be introduced without changing the v1 identifier; consumers should
ignore unknown fields. A future incompatible layout or meaning will use a new
schema identifier.

Internal keys under `calculations.scalar_outputs` follow Path of Building and
may change as calculation internals evolve. Keys under `calculations.summary`
are the stable integration surface for the commonly used values listed there.
Unavailable optional values are omitted consistently.

## `jq` examples

Show character identity and life:

```sh
jq '{character, life: .calculations.summary.life}' pob_analysis_*.json
```

List equipped slots and item names:

```sh
jq '.equipment[] | {slot, name, enabled}' pob_analysis_*.json
```

List enabled gems:

```sh
jq '.skill_groups[] | .label as $group | .gems[] | select(.enabled) | {group: $group, name, level, quality}' pob_analysis_*.json
```

Inspect calculation warnings and non-null summary values:

```sh
jq '{warnings: .export_warnings, summary: (.calculations.summary | with_entries(select(.value != null)))}' pob_analysis_*.json
```
