// Strict JSON syntax and duplicate-key check, available on .NET Framework 4.x and .NET 8.
// PowerShell ConvertFrom-Json still builds the object; this preflight prevents its
// version-dependent acceptance of duplicate keys, comments and trailing commas.
using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;
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
                    if(pos+4>text.Length || !Regex.IsMatch(text.Substring(pos,4),"^[0-9a-fA-F]{4}$"))Error("Invalid Unicode escape");
                    result.Append((char)Convert.ToInt32(text.Substring(pos,4),16));pos+=4;break;
                default:Error("Invalid JSON escape");break;
            }
        }
        Error("Unterminated JSON string");return null;
    }
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
        else {
            var m=Regex.Match(text.Substring(pos),"^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)");
            if(!m.Success)Error("Invalid JSON value");pos+=m.Length;
        }
        depth--;
    }
    public static void Check(string value) {
        var parser=new ScienceStrictJson(value);parser.Value();parser.Space();
        if(parser.pos!=value.Length)parser.Error("Unexpected JSON content");
    }
}
