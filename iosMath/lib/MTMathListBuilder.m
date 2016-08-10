//
//  MTMathListBuilder.m
//  iosMath
//
//  Created by Kostub Deshmukh on 8/28/13.
//  Copyright (C) 2013 MathChat
//   
//  This software may be modified and distributed under the terms of the
//  MIT license. See the LICENSE file for details.
//

#import "MTMathListBuilder.h"
#import "MTMathAtomFactory.h"

NSString *const MTParseError = @"ParseError";

@implementation MTMathListBuilder {
    unichar* _chars;
    int _currentChar;
    NSUInteger _length;
    MTInner* _currentInnerAtom;
}

- (instancetype)initWithString:(NSString *)str
{
    self = [super init];
    if (self) {
        _error = nil;
        _chars = malloc(sizeof(unichar)*str.length);
        _length = str.length;
        [str getCharacters:_chars range:NSMakeRange(0, str.length)];
        _currentChar = 0;
    }
    return self;
}

- (void)dealloc
{
    free(_chars);
}

- (BOOL) hasCharacters
{
    return _currentChar < _length;
}

// gets the next character and moves the pointer ahead
- (unichar) getNextCharacter
{
    NSAssert([self hasCharacters], @"Retrieving character at index %d beyond length %lu", _currentChar, (unsigned long)_length);
    return _chars[_currentChar++];
}

- (void) unlookCharacter
{
    NSAssert(_currentChar > 0, @"Unlooking when at the first character.");
    _currentChar--;
}

- (MTMathList *)build
{
    MTMathList* list = [self buildInternal:false];
    if ([self hasCharacters] && !_error) {
        // something went wrong most likely braces mismatched
        NSString* errorMessage = [NSString stringWithFormat:@"Mismatched braces: %@", [NSString stringWithCharacters:_chars length:_length]];
        [self setError:MTParseErrorMismatchBraces message:errorMessage];
    }
    if (_error) {
        return nil;
    }
    return list;
}

- (MTMathList*) buildInternal:(BOOL) oneCharOnly
{
    return [self buildInternal:oneCharOnly stopChar:0];
}

- (MTMathList*)buildInternal:(BOOL) oneCharOnly stopChar:(unichar) stop
{
    MTMathList* list = [MTMathList new];
    NSAssert(!(oneCharOnly && (stop > 0)), @"Cannot set both oneCharOnly and stopChar.");
    MTMathAtom* prevAtom = nil;
    while([self hasCharacters]) {
        if (_error) {
            // If there is an error thus far then bail out.
            return nil;
        }
        MTMathAtom* atom = nil;
        unichar ch = [self getNextCharacter];
        if (oneCharOnly) {
            if (ch == '^' || ch == '}' || ch == '_') {
                // this is not the character we are looking for.
                // They are meant for the caller to look at.
                [self unlookCharacter];
                return list;
            }
        }
        // If there is a stop character, keep scanning till we find it
        if (stop > 0 && ch == stop) {
            return list;
        }
        
        if (ch == '^') {
            NSAssert(!oneCharOnly, @"This should have been handled before");
            
            if (!prevAtom || prevAtom.superScript || !prevAtom.scriptsAllowed) {
                // If there is no previous atom, or if it already has a superscript
                // or if scripts are not allowed for it, then add an empty node.
                prevAtom = [MTMathAtom atomWithType:kMTMathAtomOrdinary value:@""];
                [list addAtom:prevAtom];
            }
            // this is a superscript for the previous atom
            // note: if the next char is the stopChar it will be consumed by the ^ and so it doesn't count as stop
            prevAtom.superScript = [self buildInternal:true];
            continue;
        } else if (ch == '_') {
            NSAssert(!oneCharOnly, @"This should have been handled before");
            
            if (!prevAtom || prevAtom.subScript || !prevAtom.scriptsAllowed) {
                // If there is no previous atom, or if it already has a subcript
                // or if scripts are not allowed for it, then add an empty node.
                prevAtom = [MTMathAtom atomWithType:kMTMathAtomOrdinary value:@""];
                [list addAtom:prevAtom];
            }
            // this is a subscript for the previous atom
            // note: if the next char is the stopChar it will be consumed by the _ and so it doesn't count as stop
            prevAtom.subScript = [self buildInternal:true];
            continue;
        } else if (ch == '{') {
            // this puts us in a recursive routine, and sets oneCharOnly to false and no stop character
            MTMathList* sublist = [self buildInternal:false stopChar:'}'];
            prevAtom = [sublist.atoms lastObject];
            [list append:sublist];
            if (oneCharOnly) {
                return list;
            }
            continue;
        } else if (ch == '}') {
            NSAssert(!oneCharOnly, @"This should have been handled before");
            NSAssert(stop == 0, @"This should have been handled before");
            // We encountered a closing brace when there is no stop set, that means there was no
            // corresponding opening brace.
            NSString* errorMessage = [NSString stringWithFormat:@"Mismatched braces."];
            [self setError:MTParseErrorMismatchBraces message:errorMessage];
            return nil;
        } else if (ch == '\\') {
            // \ means a command
            NSString* command = [self readCommand];
            MTMathList* done = [self stopCommand:command list:list stopChar:stop];
            if (done) {
                return done;
            } else if (_error) {
                return nil;
            }
            atom = [self atomForCommand:command];
            if (atom == nil) {
                // this was an unknown command,
                // we flag an error and return.
                return nil;
            }
        } else {
            atom = [MTMathAtomFactory atomForCharacter:ch];
            if (!atom) {
                // Not a recognized character
                continue;
            }
        }
        NSAssert(atom != nil, @"Atom shouldn't be nil");
        [list addAtom:atom];
        prevAtom = atom;
        
        if (oneCharOnly) {
            // we consumed our onechar
            return list;
        }
    }
    if (stop > 0) {
        if (stop == '}') {
            // We did not find a corresponding closing brace.
            [self setError:MTParseErrorMismatchBraces message:@"Missing closing brace"];
        } else {
            // we never found our stop character
            NSString* errorMessage = [NSString stringWithFormat:@"Expected character not found: %d", stop];
            [self setError:MTParseErrorCharacterNotFound message:errorMessage];
        }
    }
    return list;
}

- (NSString*) readCommand
{
    static NSSet<NSNumber*>* singleCharCommands = nil;
    if (!singleCharCommands) {
        NSArray* singleChars = @[ @'{', @'}', @'$', @'#', @'%', @'_', @'|', @' ', @',', @'>', @';', @'!' ];
        singleCharCommands = [[NSSet alloc] initWithArray:singleChars];
    }
    // a command is a string of all upper and lower case characters.
    NSMutableString* mutable = [NSMutableString string];
    while([self hasCharacters]) {
        unichar ch = [self getNextCharacter];
        // Single char commands
        if (mutable.length == 0 && [singleCharCommands containsObject:@(ch)]) {
            // These are single char commands.
            [mutable appendString:[NSString stringWithCharacters:&ch length:1]];
            break;
        } else if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
            [mutable appendString:[NSString stringWithCharacters:&ch length:1]];
        } else {
            // we went too far
            [self unlookCharacter];
            break;
        }
    }
    return mutable;
}

- (NSString*) readDelimiter
{
    while([self hasCharacters]) {
        unichar ch = [self getNextCharacter];
        // Ignore spaces and nonascii.
        if (ch < 0x21 || ch > 0x7E) {
            // skip non ascii characters and spaces
            continue;
        } else if (ch == '\\') {
            // \ means a command
            NSString* command = [self readCommand];
            if ([command isEqualToString:@"|"]) {
                // | is a command and also a regular delimiter. We use the || command to
                // distinguish between the 2 cases for the caller.
                return @"||";
            }
            return command;
        } else {
            return [NSString stringWithCharacters:&ch length:1];
        }
    }
    // We ran out of characters for delimiter
    return nil;
}

- (MTMathAtom*) getBoundaryAtom:(NSString*) delimiterType
{
    NSString* delim = [self readDelimiter];
    if (!delim) {
        NSString* errorMessage = [NSString stringWithFormat:@"Missing delimiter for \\%@", delimiterType];
        [self setError:MTParseErrorMissingDelimiter message:errorMessage];
        return nil;
    }
    MTMathAtom* boundary = [MTMathAtomFactory boundaryAtomForDelimiterName:delim];
    if (!boundary) {
        NSString* errorMessage = [NSString stringWithFormat:@"Invalid delimiter for \\%@: %@", delimiterType, delim];
        [self setError:MTParseErrorInvalidDelimiter message:errorMessage];
        return nil;
    }
    return boundary;
}

- (MTMathAtom*) atomForCommand:(NSString*) command
{
    MTMathAtom* atom = [MTMathAtomFactory atomForLatexSymbolName:command];
    if (atom) {
        return atom;
    }
    MTAccent* accent = [MTMathAtomFactory accentWithName:command];
    if (accent) {
        // The command is an accent
        accent.innerList = [self buildInternal:true];
        return accent;
    } else if ([command isEqualToString:@"frac"]) {
        // A fraction command has 2 arguments
        MTFraction* frac = [MTFraction new];
        frac.numerator = [self buildInternal:true];
        frac.denominator = [self buildInternal:true];
        return frac;
    } else if ([command isEqualToString:@"binom"]) {
        // A binom command has 2 arguments
        MTFraction* frac = [[MTFraction alloc] initWithRule:NO];
        frac.numerator = [self buildInternal:true];
        frac.denominator = [self buildInternal:true];
        frac.leftDelimiter = @"(";
        frac.rightDelimiter = @")";
        return frac;
    } else if ([command isEqualToString:@"sqrt"]) {
        // A sqrt command with one argument
        MTRadical* rad = [MTRadical new];
        unichar ch = [self getNextCharacter];
        if (ch == '[') {
            // special handling for sqrt[degree]{radicand}
            rad.degree = [self buildInternal:false stopChar:']'];
            rad.radicand = [self buildInternal:true];
        } else {
            [self unlookCharacter];
            rad.radicand = [self buildInternal:true];
        }
        return rad;
    } else if ([command isEqualToString:@"left"]) {
        // Save the current inner while a new one gets built.
        MTInner* oldInner = _currentInnerAtom;
        _currentInnerAtom = [MTInner new];
        _currentInnerAtom.leftBoundary = [self getBoundaryAtom:@"left"];
        if (!_currentInnerAtom.leftBoundary) {
            return nil;
        }
        _currentInnerAtom.innerList = [self buildInternal:false];
        if (!_currentInnerAtom.rightBoundary) {
            // A right node would have set the right boundary so we must be missing the right node.
            NSString* errorMessage = @"Missing \\right";
            [self setError:MTParseErrorMissingRight message:errorMessage];
            return nil;
        }
        // reinstate the old inner atom.
        MTInner* newInner = _currentInnerAtom;
        _currentInnerAtom = oldInner;
        return newInner;
    } else if ([command isEqualToString:@"overline"]) {
        // The overline command has 1 arguments
        MTOverLine* over = [MTOverLine new];
        over.innerList = [self buildInternal:true];
        return over;
    } else if ([command isEqualToString:@"underline"]) {
        // The underline command has 1 arguments
        MTUnderLine* under = [MTUnderLine new];
        under.innerList = [self buildInternal:true];
        return under;
    } else {
        NSString* errorMessage = [NSString stringWithFormat:@"Invalid command \\%@", command];
        [self setError:MTParseErrorInvalidCommand message:errorMessage];
        return nil;
    }
}

- (MTMathList*) stopCommand:(NSString*) command list:(MTMathList*) list stopChar:(unichar) stopChar
{
    static NSDictionary<NSString*, NSArray*>* fractionCommands = nil;
    if (!fractionCommands) {
        fractionCommands = @{ @"over" : @[],
                              @"atop" : @[],
                              @"choose" : @[ @"(", @")"],
                              @"brack" : @[ @"[", @"]"],
                              @"brace" : @[ @"{", @"}"]};
    }
    if ([command isEqualToString:@"right"]) {
        if (!_currentInnerAtom) {
            NSString* errorMessage = @"Missing \\left";
            [self setError:MTParseErrorMissingLeft message:errorMessage];
            return nil;
        }
        _currentInnerAtom.rightBoundary = [self getBoundaryAtom:@"right"];
        if (!_currentInnerAtom.rightBoundary) {
            return nil;
        }
        // return the list read so far.
        return list;
    } else if ([fractionCommands objectForKey:command]) {
        MTFraction* frac = nil;
        if ([command isEqualToString:@"over"]) {
            frac = [[MTFraction alloc] init];
        } else {
            frac = [[MTFraction alloc] initWithRule:NO];
        }
        NSArray* delims = [fractionCommands objectForKey:command];
        if (delims.count == 2) {
            frac.leftDelimiter = delims[0];
            frac.rightDelimiter = delims[1];
        }
        frac.numerator = list;
        frac.denominator = [self buildInternal:NO stopChar:stopChar];
        if (_error) {
            return nil;
        }
        MTMathList* fracList = [MTMathList new];
        [fracList addAtom:frac];
        return fracList;
    }
    return nil;
}

- (void) setError:(MTParseErrors) code message:(NSString*) message
{
    // Only record the first error.
    if (!_error) {
        _error = [NSError errorWithDomain:MTParseError code:code userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
}

+ (NSDictionary*) spaceToCommands
{
    static NSDictionary* spaceToCommands = nil;
    if (!spaceToCommands) {
        spaceToCommands = @{
                            @3 : @",",
                            @4 : @">",
                            @5 : @";",
                            @(-3) : @"!",
                            @18 : @"quad",
                            @36 : @"qquad",
                    };
    }
    return spaceToCommands;
}

+ (NSDictionary*) styleToCommands
{
    static NSDictionary* styleToCommands = nil;
    if (!styleToCommands) {
        styleToCommands = @{
                            @(kMTLineStyleDisplay) : @"displaystyle",
                            @(kMTLineStyleText) : @"textstyle",
                            @(kMTLineStyleScript) : @"scriptstyle",
                            @(kMTLineStyleScriptScript) : @"scriptscriptstyle",
                            };
    }
    return styleToCommands;
}

+ (MTMathList *)buildFromString:(NSString *)str
{
    MTMathListBuilder* builder = [[MTMathListBuilder alloc] initWithString:str];
    return builder.build;
}

+ (MTMathList *)buildFromString:(NSString *)str error:(NSError *__autoreleasing *)error
{
    MTMathListBuilder* builder = [[MTMathListBuilder alloc] initWithString:str];
    MTMathList* output = [builder build];
    if (builder.error) {
        if (error) {
            *error = builder.error;
        }
        return nil;
    }
    return output;
}

+ (NSString*) delimToString:(MTMathAtom*) delim
{
    NSString* command = [MTMathAtomFactory delimiterNameForBoundaryAtom:delim];
    if (command) {
        NSArray<NSString*>* singleChars = @[ @"(", @")", @"[", @"]", @"<", @">", @"|", @".", @"/"];
        if ([singleChars containsObject:command]) {
            return command;
        } else if ([command isEqualToString:@"||"]) {
            return @"\\|"; // special case for ||
        } else {
            return [NSString stringWithFormat:@"\\%@", command];
        }
    }
    return @"";
}

+ (NSString *)mathListToString:(MTMathList *)ml
{
    NSMutableString* str = [NSMutableString string];
    for (MTMathAtom* atom in ml.atoms) {
        if (atom.type == kMTMathAtomFraction) {
            MTFraction* frac = (MTFraction*) atom;
            if (frac.hasRule) {
                [str appendFormat:@"\\frac{%@}{%@}", [self mathListToString:frac.numerator], [self mathListToString:frac.denominator]];
            } else {
                NSString* command = nil;
                if (!frac.leftDelimiter && !frac.rightDelimiter) {
                    command = @"atop";
                } else if ([frac.leftDelimiter isEqualToString:@"("] && [frac.rightDelimiter isEqualToString:@")"]) {
                    command = @"choose";
                } else if ([frac.leftDelimiter isEqualToString:@"{"] && [frac.rightDelimiter isEqualToString:@"}"]) {
                    command = @"brace";
                } else if ([frac.leftDelimiter isEqualToString:@"["] && [frac.rightDelimiter isEqualToString:@"]"]) {
                    command = @"brack";
                } else {
                    command = [NSString stringWithFormat:@"atopwithdelims%@%@", frac.leftDelimiter, frac.rightDelimiter];
                }
                [str appendFormat:@"{%@ \\%@ %@}", [self mathListToString:frac.numerator], command, [self mathListToString:frac.denominator]];
            }
        } else if (atom.type == kMTMathAtomRadical) {
            [str appendString:@"\\sqrt"];
            MTRadical* rad = (MTRadical*) atom;
            if (rad.degree) {
                [str appendFormat:@"[%@]", [self mathListToString:rad.degree]];
            }
            [str appendFormat:@"{%@}", [self mathListToString:rad.radicand]];
        } else if (atom.type == kMTMathAtomInner) {
            MTInner* inner = (MTInner*) atom;
            if (inner.leftBoundary || inner.rightBoundary) {
                if (inner.leftBoundary) {
                    [str appendFormat:@"\\left%@ ", [self delimToString:inner.leftBoundary]];
                } else {
                    [str appendString:@"\\left. "];
                }
                [str appendString:[self mathListToString:inner.innerList]];
                if (inner.rightBoundary) {
                    [str appendFormat:@"\\right%@ ", [self delimToString:inner.rightBoundary]];
                } else {
                    [str appendString:@"\\right. "];
                }
            } else {
                [str appendFormat:@"{%@}", [self mathListToString:inner.innerList]];
            }
        } else if (atom.type == kMTMathAtomOverline) {
            [str appendString:@"\\overline"];
            MTOverLine* over = (MTOverLine*) atom;
            [str appendFormat:@"{%@}", [self mathListToString:over.innerList]];
        } else if (atom.type == kMTMathAtomUnderline) {
            [str appendString:@"\\underline"];
            MTUnderLine* under = (MTUnderLine*) atom;
            [str appendFormat:@"{%@}", [self mathListToString:under.innerList]];
        } else if (atom.type == kMTMathAtomAccent) {
            MTAccent* accent = (MTAccent*) atom;
            [str appendFormat:@"\\%@{%@}", [MTMathAtomFactory accentName:accent], [self mathListToString:accent.innerList]];
        } else if (atom.type == kMTMathAtomSpace) {
            MTMathSpace* space = (MTMathSpace*) atom;
            NSDictionary* spaceToCommands = [MTMathListBuilder spaceToCommands];
            NSString* command = spaceToCommands[@(space.space)];
            if (command) {
                [str appendFormat:@"\\%@ ", command];
            } else {
                [str appendFormat:@"\\mkern%.1fmu", space.space];
            }
        } else if (atom.type == kMTMathAtomStyle) {
            MTMathStyle* style = (MTMathStyle*) atom;
            NSDictionary* styleToCommands = [MTMathListBuilder styleToCommands];
            NSString* command = styleToCommands[@(style.style)];
            [str appendFormat:@"\\%@ ", command];
        } else if (atom.nucleus.length == 0) {
            [str appendString:@"{}"];
        } else if ([atom.nucleus isEqualToString:@"\u2236"]) {
            // math colon
            [str appendString:@":"];
        } else if ([atom.nucleus isEqualToString:@"\u2212"]) {
            // math minus
            [str appendString:@"-"];
        } else {
            NSString* command = [MTMathAtomFactory latexSymbolNameForAtom:atom];
            if (command) {
                [str appendFormat:@"\\%@ ", command];
            } else {
                [str appendString:atom.nucleus];
            }
        }
        
        if (atom.superScript) {
            [str appendFormat:@"^{%@}", [self mathListToString:atom.superScript]];
        }
        
        if (atom.subScript) {
            [str appendFormat:@"_{%@}", [self mathListToString:atom.subScript]];
        }
    }
    return [str copy];
}

@end
