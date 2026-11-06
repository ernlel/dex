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
    static if (is(T == JSONValue))
    {
        return value;
    }
    else static if (is(T == typeof(null)))
    {
        return JSONValue(null);
    }
    else static if (is(T : bool))
    {
        return JSONValue(value);
    }
    else static if (is(T == enum))
    {
        return JSONValue(to!string(value));
    }
    else static if (isIntegral!T)
    {
        static if (isUnsigned!T)
            return JSONValue(cast(ulong) value);
        else
            return JSONValue(cast(long) value);
    }
    else static if (isFloatingPoint!T)
    {
        const d = cast(double) value;
        return isFinite(d) ? JSONValue(d) : JSONValue(null);
    }
    else static if (isSomeString!T)
    {
        return JSONValue(value);
    }
    else static if (is(T == Nullable!U, U))
    {
        return value.isNull ? JSONValue(null) : toJSONValue(value.get);
    }
    else static if (isStaticArray!T || isDynamicArray!T)
    {
        JSONValue[] items;
        items.reserve(value.length);
        foreach (item; value)
            items ~= toJSONValue(item);
        return JSONValue(items);
    }
    else static if (isAssociativeArray!T)
    {
        JSONValue[string] object;
        foreach (key, item; value)
            object[to!string(key)] = toJSONValue(item);
        return JSONValue(object);
    }
    else static if (isPointer!T)
    {
        return value is null ? JSONValue(null) : toJSONValue(*value);
    }
    else static if (is(T == struct) || is(T == class))
    {
        static if (is(T == class) && __traits(compiles, value is null))
        {
            if (value is null)
                return JSONValue(null);
        }

        static if (hasMember!(T, "toJSON") &&
                   is(typeof(value.toJSON()) : JSONValue))
        {
            return value.toJSON();
        }
        else
        {
            JSONValue[string] object;
            static if (is(T == class) && BaseClassesTuple!T.length > 0)
            {
                alias Base = BaseClassesTuple!T[0];
                auto baseObject = toJSONValue(cast(Base) value);
                foreach (key, item; baseObject.object)
                    object[key] = item;
            }
            alias fieldNames = FieldNameTuple!T;
            static assert(fieldNames.length == T.tupleof.length,
                          "Cannot reflect over fields of " ~ T.stringof);
            foreach (i, field; value.tupleof)
                object[fieldNames[i]] = toJSONValue(field);
            return JSONValue(object);
        }
    }
    else
    {
        static assert(false, "Cannot serialize " ~ T.stringof ~ " to JSON");
    }
}
