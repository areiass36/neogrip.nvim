package neogrip.rpc;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Marks a function as an RPC method. The wire name is the Java method's own
 * name, prefixed by the class's {@link RpcNamespace} when present; there is
 * deliberately no name attribute to drift from the code.
 *
 * lane says which thread answers: "read" runs on the read loop itself (always
 * answerable, even mid-query - cancel and ping live there), "worker" is the
 * single statement worker, and any other name is an exclusive lane of its own
 * where only one call runs at a time (the introspect sweep).
 */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface RpcMethod {
    String lane() default "worker";
}
