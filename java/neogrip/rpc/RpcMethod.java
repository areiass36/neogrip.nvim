package neogrip.rpc;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Marks a function as an RPC method. The wire name is the Java method's own
 * name, prefixed by the class's {@link RpcNamespace} when present; there is
 * deliberately no name attribute to drift from the code, and no threading
 * attribute either: every request runs on its own virtual thread (ADR-0028),
 * and whatever must be serialized - the shared session connection - is its
 * owner's lock, not the handler's declaration.
 */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface RpcMethod {}
