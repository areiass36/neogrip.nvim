package neogrip.rpc;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * The wire name of a record component, for the handful of fields whose wire
 * spelling is not a Java one: {@code @Json("is_pk") boolean isPk}. Components
 * without it serialize under their own name.
 */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.RECORD_COMPONENT)
public @interface Json {
    String value();
}
