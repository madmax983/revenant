/**
 * @description Resolves workflow-related Apex class names to concrete Types across
 * subscriber and package namespaces, applying an ordered chain of fallback
 * strategies and caching results so managed-package and sandbox contexts behave
 * consistently.
 */
public inherited sharing class WorkflowTypeResolver {
  @TestVisible
  private static String mockPackageNamespace = null;
  @TestVisible
  private static Boolean simulateNamespacedContext = false;

  @TestVisible
  private static Map<String, Type> typeCache = new Map<String, Type>();

  /**
   * @description Resolves a class name to its Type with no explicit context
   * namespace, applying the default fallback chain.
   * @param name The class name to resolve.
   * @return The resolved Type, or null if the name is blank or cannot be resolved.
   */
  public static Type resolve(String name) {
    return resolve(name, null);
  }

  /**
   * @description Resolves a class name to its Type, consulting the cache first and
   * otherwise running the ordered fallback strategies. Blank names resolve to null,
   * and both hits and misses are cached under a key that includes the context
   * namespace.
   * @param name The class name to resolve.
   * @param contextNamespace An optional namespace to disambiguate the name, or null.
   * @return The resolved Type, or null if the name cannot be resolved.
   */
  public static Type resolve(String name, String contextNamespace) {
    if (String.isBlank(name)) {
      return null;
    }
    String cacheKey = (name +
      (contextNamespace != null ? ('|' + contextNamespace) : ''))
      .toLowerCase();
    if (typeCache.containsKey(cacheKey)) {
      return typeCache.get(cacheKey);
    }

    Type t = doResolve(name, contextNamespace);
    typeCache.put(cacheKey, t);
    return t;
  }

  private static Type doResolve(String name, String contextNamespace) {
    // Each strategy returns a resolved Type or null; the first non-null wins,
    // in the same priority order as the original inline fallback chain.
    Type t = resolveDotQualified(name);
    if (t != null) {
      return t;
    }

    t = resolveByContextNamespace(name, contextNamespace);
    if (t != null) {
      return t;
    }

    t = resolveByCallerOrSimulatedPackage(name);
    if (t != null) {
      return t;
    }

    // Local namespace fallback (subscriber namespace).
    t = Type.forName('', name);
    if (t != null) {
      return t;
    }

    t = resolveByPackageNamespace(name);
    if (t != null) {
      return t;
    }

    return resolveSandboxPortability(name);
  }

  /**
   * @description Strategy 1: namespace-qualified resolution when the name contains
   * a dot. Under simulation, a name prefixed with the simulated package namespace
   * maps to the local (empty) namespace.
   * @param name The dot-qualified class name to resolve.
   * @return The resolved Type, or null if the name has no dot.
   */
  private static Type resolveDotQualified(String name) {
    if (!name.contains('.')) {
      return null;
    }
    String ns = name.substringBefore('.');
    String localName = name.substringAfter('.');
    if (simulateNamespacedContext && ns == getPackageNamespace()) {
      return Type.forName('', localName);
    }
    return Type.forName(ns, localName);
  }

  /**
   * @description Strategy 2: context namespace, when provided (resolves a collision
   * in the subscriber namespace).
   * @param name The class name to resolve.
   * @param contextNamespace The namespace to resolve against, or null to skip.
   * @return The resolved Type, or null if no context namespace was supplied.
   */
  private static Type resolveByContextNamespace(
    String name,
    String contextNamespace
  ) {
    if (contextNamespace == null) {
      return null;
    }
    return Type.forName(contextNamespace, name);
  }

  /**
   * @description Strategy 3: standard/caller resolution. Outside simulation this is
   * the single-arg Type.forName (package or caller namespace); under simulation only
   * names explicitly prefixed with the simulated package namespace resolve.
   * @param name The class name to resolve.
   * @return The resolved Type, or null when simulating and the name is unprefixed.
   */
  private static Type resolveByCallerOrSimulatedPackage(String name) {
    if (!simulateNamespacedContext) {
      return Type.forName(name);
    }
    String pkg = getPackageNamespace();
    if (String.isNotBlank(pkg) && name.startsWith(pkg + '.')) {
      return Type.forName(name.substringAfter(pkg + '.'));
    }
    return null;
  }

  /**
   * @description Strategy 5: package namespace fallback, resolving the name against
   * the managed-package namespace when one is present.
   * @param name The class name to resolve.
   * @return The resolved Type, or null when there is no package namespace.
   */
  private static Type resolveByPackageNamespace(String name) {
    String packageNamespace = getPackageNamespace();
    if (String.isNotBlank(packageNamespace)) {
      return Type.forName(packageNamespace, name);
    }
    return null;
  }

  /**
   * @description Strategy 6: sandbox portability fallback. When a namespaced name
   * failed to resolve, retry with the namespace stripped against the local and
   * package namespaces.
   * @param name The dot-qualified class name to resolve.
   * @return The resolved Type, or null if the name has no dot or cannot resolve.
   */
  private static Type resolveSandboxPortability(String name) {
    if (!name.contains('.')) {
      return null;
    }
    String localName = name.substringAfter('.');
    Type t = Type.forName('', localName);
    if (t != null) {
      return t;
    }
    String packageNamespace = getPackageNamespace();
    if (String.isNotBlank(packageNamespace)) {
      return Type.forName(packageNamespace, localName);
    }
    return null;
  }

  /**
   * @description Returns the namespace this engine is deployed under, honoring the
   * test mock override and otherwise deriving it from the WorkflowEngine class name.
   * @return The package namespace, or an empty string when running unmanaged.
   */
  public static String getPackageNamespace() {
    if (mockPackageNamespace != null) {
      return mockPackageNamespace;
    }
    String className = WorkflowEngine.class.getName();
    if (className.contains('.')) {
      return className.substringBefore('.');
    }
    return '';
  }

  /**
   * @description Extracts the namespace prefix from a dot-qualified workflow name.
   * @param workflowName The workflow name, optionally namespace-qualified.
   * @return The namespace portion, or an empty string when the name is unqualified.
   */
  public static String extractNamespace(String workflowName) {
    if (String.isNotBlank(workflowName) && workflowName.contains('.')) {
      return workflowName.substringBefore('.');
    }
    return '';
  }
}
