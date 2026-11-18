// Strict JSON syntax and duplicate-key check, available on .NET Framework 4.x and .NET 8.
// PowerShell ConvertFrom-Json still builds the object; this preflight prevents its
// version-dependent acceptance of duplicate keys, comments and trailing commas.
using System;
using System.Collections.Generic;
using System.Text;
public sealed class ScienceStrictJson {
    string text; int pos; int depth;
    ScienceStrictJson(string value) { text=value; }
    void Error(string message) { throw new FormatException(message+" at JSON character "+pos); }
    void Space() { while(pos<text.Length && (text[pos]==' '||text[pos]=='\n'||text[pos]=='\r'||text[pos]=='\t')) pos++; }
    bool Take(char c) { Space(); if(pos<text.Length && text[pos]==c){pos++;return true;}return false; }
    void Need(char c) { if(!Take(c))Error("Expected "+c); }
    string Str() {
        Space(); Need('"'); var result=new StringBuilder();
        while(pos<text.Length) {
            char c=text[pos++];
            if(c=='"')return result.ToString();
            if(c<32)Error("Control character in JSON string");
            if(c!='\\'){result.Append(c);continue;}
            if(pos==text.Length)Error("Incomplete JSON escape");
            c=text[pos++];
            switch(c) {
                case '"': case '\\': case '/': result.Append(c);break;
                case 'b':result.Append('\b');break;case 'f':result.Append('\f');break;
                case 'n':result.Append('\n');break;case 'r':result.Append('\r');break;case 't':result.Append('\t');break;
                case 'u':
                    if(pos+4>text.Length || !Hex(text[pos]) || !Hex(text[pos+1]) || !Hex(text[pos+2]) || !Hex(text[pos+3]))Error("Invalid Unicode escape");
                    result.Append((char)Convert.ToInt32(text.Substring(pos,4),16));pos+=4;break;
                default:Error("Invalid JSON escape");break;
            }
        }
        Error("Unterminated JSON string");return null;
    }
    static bool Digit(char c) { return c >= '0' && c <= '9'; }
    bool At(char c) { return pos < text.Length && text[pos] == c; }
    void Digits() {
        int start = pos;
        while (pos < text.Length && Digit(text[pos])) pos++;
        if (pos == start) Error("Expected JSON digit");
    }
    void Number() {
        if (At('-')) pos++;
        if (At('0')) pos++;
        else Digits();
        if (At('.')) { pos++; Digits(); }
        if (At('e') || At('E')) {
            pos++;
            if (At('+') || At('-')) pos++;
            Digits();
        }
    }
    void Literal(string value) {
        if (text.Length - pos < value.Length ||
            String.CompareOrdinal(text, pos, value, 0, value.Length) != 0) Error("Invalid JSON literal");
        pos += value.Length;
    }
    static bool Hex(char c) { return Digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
    void Value() {
        Space();if(++depth>64)Error("JSON nesting is too deep");
        if(pos==text.Length)Error("Missing JSON value");
        char c=text[pos];
        if(c=='{') {
            pos++;var keys=new HashSet<string>(StringComparer.Ordinal);Space();
            if(!Take('}')) { while(true) {
                string key=Str();if(!keys.Add(key))Error("Duplicate JSON key: "+key);
                Need(':');Value();if(Take('}'))break;Need(',');
            }}
        } else if(c=='[') {
            pos++;if(!Take(']')) { while(true) {Value();if(Take(']'))break;Need(',');} }
        } else if(c=='"')Str();
        else if(c=='t') Literal("true");
        else if(c=='f') Literal("false");
        else if(c=='n') Literal("null");
        else if(c=='-' || Digit(c)) Number();
        else Error("Invalid JSON value");
        depth--;
    }
    public static void Check(string value) {
        var parser=new ScienceStrictJson(value);parser.Value();parser.Space();
        if(parser.pos!=value.Length)parser.Error("Unexpected JSON content");
    }
}
