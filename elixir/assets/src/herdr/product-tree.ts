export type ProductTreeDependencyEndpoint = {
  kind?: "work_package" | string | null;
  id?: string | null;
};

export type ProductTreeDependencyEdge = {
  id: string;
  source?: ProductTreeDependencyEndpoint;
  target?: ProductTreeDependencyEndpoint;
  kind?: string | null;
  reason?: string | null;
  decision_ref?: Record<string, unknown> | null;
  created_by?: string | null;
  created_at?: string | null;
};

export type ProductTreeExecutionGraph = {
  available?: boolean;
  work_package_ids?: string[];
  effective_edges?: Array<{
    prerequisite_work_package_id: string;
    dependent_work_package_id: string;
    dependency_ids?: string[];
  }>;
  topological_order?: string[];
  cycles?: string[][];
};

export type ProductTreeProjection = {
  available?: boolean;
  dependency_edges?: ProductTreeDependencyEdge[];
  execution_graph?: ProductTreeExecutionGraph;
  summary?: {
    work_package_count?: number;
    attention_count?: number;
    guidance_count?: number;
    blocker_count?: number;
  };
  latest_revision?: {
    id?: string | null;
    revision_number?: number;
    reason?: string | null;
    decision_ref?: Record<string, unknown> | null;
    created_by?: string | null;
    created_at?: string | null;
  } | null;
  attention_items?: Array<Record<string, unknown>>;
};
