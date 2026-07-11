public inherited sharing class WorkflowTypeResolver {
  @TestVisible
  private static String mockPackageNamespace = null;
  @TestVisible
  private static Boolean simulateNamespacedContext = false;

  @TestVisible
  private static Map<String, Type> typeCache = new Map<String, Type>();

  public static Type resolve(String name) {
    return resolve(name, null);
  }

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
   * Strategy 1: namespace-qualified resolution when the name contains a dot.
   * Under simulation, a name prefixed with the simulated package namespace maps
   * to the local (empty) namespace.
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
   * Strategy 2: context namespace, when provided (resolves a collision in the
   * subscriber namespace).
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
   * Strategy 3: standard/caller resolution. Outside simulation this is the
   * single-arg Type.forName (package or caller namespace); under simulation only
   * names explicitly prefixed with the simulated package namespace resolve.
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

  /** Strategy 5: package namespace fallback. */
  private static Type resolveByPackageNamespace(String name) {
    String packageNamespace = getPackageNamespace();
    if (String.isNotBlank(packageNamespace)) {
      return Type.forName(packageNamespace, name);
    }
    return null;
  }

  /**
   * Strategy 6: sandbox portability fallback. When a namespaced name failed to
   * resolve, retry with the namespace stripped against the local and package
   * namespaces.
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

  public static String extractNamespace(String workflowName) {
    if (String.isNotBlank(workflowName) && workflowName.contains('.')) {
      return workflowName.substringBefore('.');
    }
    return '';
  }
}
