/**
 * @description Optional, opt-in self-description contract a workflow author MAY add to a
 * WorkflowDefinition (or VersionedWorkflow) implementation so the deployed-workflow Catalog
 * can show a friendly label and a description of the workflow's purpose without reading Apex
 * source. This interface is deliberately separate from (and never extended into)
 * WorkflowDefinition: existing definitions need no change and are never forced to implement
 * it. Definitions that do not implement it still appear in the Catalog, falling back to a
 * humanized class name and an "undocumented" marker. Because the descriptions live in the
 * definition class itself, they travel with a managed package (the ISV win) and add no
 * Custom Metadata to maintain.
 */
public interface WorkflowCatalogDescribable {
  /**
   * @description The human-readable label shown for this workflow in the Catalog. Return a
   * blank/null value to defer to the humanized-class-name fallback.
   * @return The friendly label for the workflow, or blank to fall back.
   */
  String catalogLabel();

  /**
   * @description A short description of what this workflow does, shown in the Catalog so a
   * new operator can understand the deployed surface without reading Apex. Return a
   * blank/null value to leave the description empty (the row is then marked "undocumented").
   * @return The description of the workflow's purpose, or blank when none is supplied.
   */
  String catalogDescription();
}
