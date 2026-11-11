// Areas are how the operator thinks about the portfolio; repositories are only how work is filed.
// The mapping is operator-owned configuration and is never part of this code. Up to three levels are supported.
// Without a rule, a GitHub repository is filed under its owner.
export type AreaRule = [pattern: string, area: string[]];
export type Slug = { owner: string; name: string };

// A GitHub owner/name, written as the slug or as a GitHub remote. Local paths and bare names have no owner.
const SLUG = /^(?:https?:\/\/github\.com\/|git@github\.com:)?([a-z\d](?:[a-z\d-]*[a-z\d])?)\/([\w.-]+?)(?:\.git)?\/?$/i;

let rules: Array<[RegExp, string[]]> = [];

export function setAreas(next: AreaRule[]) {
  rules = next.map(([pattern, area]) => [new RegExp(pattern, "i"), area]);
}

// The first of the given spellings of a repository that names its GitHub owner.
export function githubSlug(...repos: Array<string | null | undefined>): Slug | null {
  for (const repo of repos) {
    const match = repo ? SLUG.exec(repo.trim()) : null;
    if (match) return { owner: match[1], name: match[2] };
  }
  return null;
}

export function areaFor(repo: string, slug = githubSlug(repo)): string[] {
  const ruled = rules.find(([pattern]) => pattern.test(repo))?.[1];
  if (ruled) return ruled;
  return slug ? [slug.owner, slug.name] : ["Unfiled", repo.split("/").pop() || "Unknown"];
}

export function areaLabel(area: string[]) {
  return area.join(" › ");
}
