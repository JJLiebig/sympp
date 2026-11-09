import type { WorkRequestDetail, WorkRequestPackage } from "../work-request";
import type { ProductTreeDependencyEdge, ProductTreeDependencyEndpoint, ProductTreeExecutionGraph } from "../product-tree";

import type { WorkRequestExecutionGraphModel } from "./model";

const historicalStates = new Set(["skipped", "canceled", "cancelled", "abandoned", "superseded"]);

export function workRequestExecutionGraphModel(
  detail: WorkRequestDetail,
  { includeHistorical = false }: { includeHistorical?: boolean } = {},
): WorkRequestExecutionGraphModel {
  const productTree = detail.product_tree;
  const graph = productTree?.execution_graph;
  const slices = new Map(list(detail.work_packages).map((slice) => [slice.id, slice]));
  const workPackageIds = list(graph?.work_package_ids).filter(
    (id) => includeHistorical || !isHistoricalWorkPackage(slices.get(id)),
  );

  return {
    available: graphAvailable(graph),
    base_repo: firstValue(detail.work_request.repo_key, detail.work_request.repo),
    base_branch: detail.work_request.base_branch,
    groups: groupsOf(list(detail.work_packages)),
    work_packages: workPackageIds.map((id) => mapWorkPackage(id, slices.get(id))),
    dependency_intents: list(productTree?.dependency_edges).flatMap(mapDependencyIntent),
    effective_edges: list(graph?.effective_edges),
    topological_order: list(graph?.topological_order),
    cycles: list(graph?.cycles),
  };
}

function mapDependencyIntent(edge: ProductTreeDependencyEdge) {
  const kind = edge.kind?.trim().toLowerCase();
  const source = mapDependencyEndpoint(edge.source);
  const target = mapDependencyEndpoint(edge.target);
  if (!source || !target || !["depends_on", "blocks"].includes(kind ?? "")) return [];

  const prerequisite = kind === "blocks" ? source : target;
  const dependent = kind === "blocks" ? target : source;
  return [{ id: edge.id, prerequisite, dependent }];
}

function mapDependencyEndpoint(endpoint?: ProductTreeDependencyEndpoint) {
  const id = endpoint?.id?.trim();
  if (!id) return undefined;
  return endpoint?.kind === "work_package" ? { kind: "work_package" as const, id } : undefined;
}

// A package's group is a path such as "Backend / Billing". Each prefix is a group, keyed by its path and
// nested under the one before it, positioned by the first planned package that names it.
function groupsOf(slices: WorkRequestPackage[]) {
  const groups = new Map<string, { id: string; parent_group_id: string | null; title: string; position: number; work_package_ids: string[] }>();
  for (const slice of [...slices].sort((left, right) => (left.sequence ?? 0) - (right.sequence ?? 0))) {
    const names = slice.group ? slice.group.split(" / ") : [];
    names.forEach((name, depth) => {
      const id = names.slice(0, depth + 1).join(" / ");
      if (!groups.has(id)) groups.set(id, { id, parent_group_id: depth > 0 ? names.slice(0, depth).join(" / ") : null, title: name, position: groups.size, work_package_ids: [] });
    });
    if (slice.group) groups.get(slice.group)?.work_package_ids.push(slice.id);
  }
  return [...groups.values()];
}

function mapWorkPackage(id: string, slice?: WorkRequestPackage) {
  return {
    id,
    ...workPackageReference(slice),
    ...workPackageSignals(slice),
  };
}

function workPackageReference(slice?: WorkRequestPackage) {
  return {
    ...sliceReference(slice),
    title: slice?.title,
    repo: slice?.repo,
    base_branch: slice?.base_branch,
    status: slice?.status,
    raw_status: firstValue(slice?.work_package_status, slice?.status),
    operational_state: slice?.operational_state,
  };
}

function sliceReference(slice?: WorkRequestPackage) {
  return { group_id: slice?.group, sequence: slice?.sequence };
}

function workPackageSignals(slice?: WorkRequestPackage) {
  return {
    activity_signal: slice?.activity_signal,
    worker_signal: slice?.worker_signal,
    pr_signal: slice?.pr_signal,
    review_signal: slice?.review_signal,
    dependency_signal: slice?.dependency_signal,
    merge_eligibility: slice?.merge_eligibility,
  };
}

function isHistoricalWorkPackage(slice?: WorkRequestPackage) {
  return sliceHistoryStates(slice).some(isHistoricalState);
}

function sliceHistoryStates(slice?: WorkRequestPackage) {
  return [
    slice?.status,
    slice?.work_package_status,
    slice?.delivery?.outcome,
    slice?.operational_state?.key,
    slice?.operational_state?.delivery_outcome,
  ];
}

function graphAvailable(graph?: ProductTreeExecutionGraph) {
  return graph?.available ?? false;
}

function list<T>(values?: T[] | null) {
  return values ?? [];
}

function firstValue<T>(...values: Array<T | null | undefined>) {
  return values.find((value): value is T => value != null);
}

function isHistoricalState(value: string | null | undefined) {
  return historicalStates.has(value?.trim().toLowerCase() ?? "");
}
