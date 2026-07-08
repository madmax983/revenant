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
      (String.isNotBlank(contextNamespace) ? ('|' + contextNamespace) : ''))
      .toLowerCase();
    if (typeCache.containsKey(cacheKey)) {
      return typeCache.get(cacheKey);
    }

    Type t = doResolve(name, contextNamespace);
    typeCache.put(cacheKey, t);
    return t;
  }

  private static Type doResolve(String name, String contextNamespace) {
    Type t = null;
    if (!simulateNamespacedContext) {
      // 1. Try single-arg Type.forName (package namespace or caller namespace)
      t = Type.forName(name);
      if (t != null) {
        return t;
      }
    } else {
      // Simulated packaged context: only allow resolving classes
      // that are explicitly prefixed with the simulated package namespace.
      String pkg = getPackageNamespace();
      if (String.isNotBlank(pkg) && name.startsWith(pkg + '.')) {
        t = Type.forName(name.substringAfter(pkg + '.'));
        if (t != null) {
          return t;
        }
      }
    }

    // 2. Try namespace-qualified resolution
    if (name.contains('.')) {
      String ns = name.substringBefore('.');
      String localName = name.substringAfter('.');

      // Under simulation: map simulated package namespace to local empty namespace
      if (simulateNamespacedContext && ns == getPackageNamespace()) {
        t = Type.forName('', localName);
      } else {
        t = Type.forName(ns, localName);
      }
      if (t != null) {
        return t;
      }
    }

    // 3. Try context namespace fallback if provided
    if (String.isNotBlank(contextNamespace)) {
      t = Type.forName(contextNamespace, name);
      if (t != null) {
        return t;
      }
    }

    // 4. Try local namespace fallback (subscriber namespace)
    t = Type.forName('', name);
    if (t != null) {
      return t;
    }

    // 5. Try package namespace fallback
    String packageNamespace = getPackageNamespace();
    if (String.isNotBlank(packageNamespace)) {
      t = Type.forName(packageNamespace, name);
      if (t != null) {
        return t;
      }
    }

    // 6. Sandbox portability fallback: if name has namespace but resolution failed, try stripping it
    if (name.contains('.')) {
      String localName = name.substringAfter('.');
      t = Type.forName('', localName);
      if (t != null) {
        return t;
      }
      if (String.isNotBlank(packageNamespace)) {
        t = Type.forName(packageNamespace, localName);
        if (t != null) {
          return t;
        }
      }
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
