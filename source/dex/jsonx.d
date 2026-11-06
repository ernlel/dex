/// Reflection-based conversion of D values to `std.json.JSONValue`.
module dex.jsonx;

import std.conv : to;
import std.json : JSONValue;
import std.math : isFinite;
import std.traits;
import std.typecons : Nullable;

/// Convert any supported D value into a `JSONValue`.
///
/// Supported: `JSONValue`, null, bool, integral and floating-point values,
/// strings, enums (as member names), `Nullable`, arrays, associative arrays,
/// pointers, structs and classes. Struct/class fields are serialized by name.
/// A type can customize serialization by defining `JSONValue toJSON() const`.
JSONValue toJSONValue(T)(auto ref T value)
{
    // Strip const/immutable/shared so e.g. `const JSONValue` and
    // `const Nullable!int` take the same branch as their mutable forms.
    alias U = Unqual!T;

    static if (is(U == JSONValue))
    {
        // Serialization only reads the result; dropping const is fine here.
        return cast(JSONValue) value;
    }
    else static if (is(U == typeof(null)))
    {
        return JSONValue(null);
    }
    else static if (is(U == bool))
    {
        return JSONValue(value);
    }
    else static if (is(U == enum))
    {
        return JSONValue(to!string(value));
    }
    else static if (isIntegral!U)
    {
        static if (isUnsigned!U)
            return JSONValue(cast(ulong) value);
        else
            return JSONValue(cast(long) value);
    }
    else static if (isFloatingPoint!U)
    {
        const d = cast(double) value;
        return isFinite(d) ? JSONValue(d) : JSONValue(null);
    }
    else static if (isSomeChar!U)
    {
        return JSONValue(to!string(value));
    }
    else static if (isSomeString!U)
    {
        static if (is(T : string))
            return JSONValue(value);
        else
            return JSONValue(to!string(value)); // char[], wstring, dstring
    }
    else static if (is(U == Nullable!V, V))
    {
        return value.isNull ? JSONValue(null) : toJSONValue(value.get);
    }
    else static if (isStaticArray!U || isDynamicArray!U)
    {
        JSONValue[] items;
        items.reserve(value.length);
        foreach (ref item; value)
            items ~= toJSONValue(item);
        return JSONValue(items);
    }
    else static if (isAssociativeArray!U)
    {
        JSONValue[string] object;
        foreach (key, ref item; value)
            object[to!string(key)] = toJSONValue(item);
        return JSONValue(object);
    }
    else static if (isPointer!U)
    {
        return value is null ? JSONValue(null) : toJSONValue(*value);
    }
    else static if (is(U == struct) || is(U == class))
    {
        static if (is(U == class))
        {
            if (value is null)
                return JSONValue(null);
        }

        static if (hasMember!(U, "toJSON") &&
                   is(typeof(value.toJSON()) : JSONValue))
        {
            return value.toJSON();
        }
        else
        {
            JSONValue[string] object;
            static if (is(U == class) && BaseClassesTuple!U.length > 0)
            {
                alias Base = BaseClassesTuple!U[0];
                auto baseObject = toJSONValue(cast(Base) value);
                foreach (key, item; baseObject.object)
                    object[key] = item;
            }
            alias fieldNames = FieldNameTuple!U;
            static assert(fieldNames.length == U.tupleof.length,
                          "Cannot reflect over fields of " ~ U.stringof);
            foreach (i, ref field; value.tupleof)
                object[fieldNames[i]] = toJSONValue(field);
            return JSONValue(object);
        }
    }
    else
    {
        static assert(false, "Cannot serialize " ~ T.stringof ~ " to JSON");
    }
}

unittest
{
    import std.typecons : nullable;

    const JSONValue constJson = JSONValue(["a": 1]);
    assert(toJSONValue(constJson) == constJson);

    const Nullable!int empty;
    assert(toJSONValue(empty).isNull);
    assert(toJSONValue(nullable(3)).integer == 3);

    assert(toJSONValue('x').str == "x");
    assert(toJSONValue("hé"w).str == "hé");
    assert(toJSONValue(double.nan).isNull);

    static struct Point { int x; const int y; }
    const p = Point(1, 2);
    assert(toJSONValue(p)["y"].integer == 2);
}
