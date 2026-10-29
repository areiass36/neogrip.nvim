package neogrip.rpc;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/** Prefixes every wire name in the class: @RpcNamespace("catalog") + tables() = "catalog/tables". */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface RpcNamespace {
    String value();
}
