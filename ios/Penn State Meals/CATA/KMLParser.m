/*
 Adapted from KMLParser.m by Apple Inc.

 Abstract:
 KMLElement and subclasses declared here implement a class hierarchy for storing a KML document structure. The
 actual KML file is parsed with a SAX parser and only the relevant document structure is retained in the
 object graph produced by the parser.  Data parsed is also transformed into appropriate UIKit and MapKit
 classes as necessary.

      Abstract KMLElement type.  Handles storing an element identifier (id="...") as well as a buffer for
 accumulating character data parsed from the xml. In general, subclasses should have beginElement and
 endElement classes for keeping track of parsing state.  The parser will call beginElement when an interesting
 element is encountered, then all character data found in the element will be stored into accum, and then when
 endElement is called accum will be parsed according to the conventions for that particular element type in
 order to save the data from the element.  Finally, the character data accumulator is reset.
 */

#import "KMLParser.h"
#import <CoreFoundation/CoreFoundation.h>
#import "CATAKMLCoordinateScanner.h"
#include <stdint.h>
#include <stdlib.h>

// Limits are validation limits, not a claim about the app's total footprint.
static const NSUInteger KMLMaximumInputBytes = 16 * 1024 * 1024;
static const NSUInteger KMLMaximumCoordinates = 1000000;
typedef struct {
    CLLocationCoordinate2D *values;
    size_t count, capacity;
    bool singleOnly;
    CLLocationCoordinate2D single;
} KMLCoordinateBuffer;

static bool KMLStoreCoordinate(void *context, double latitude, double longitude) {
    KMLCoordinateBuffer *buffer = context;
    if (buffer->singleOnly) {
        if (buffer->count != 0) return false;
        buffer->single = CLLocationCoordinate2DMake(latitude, longitude);
        buffer->count = 1;
        return true; // A Point never needs a heap-allocated coordinate buffer.
    }
    if (buffer->count >= KMLMaximumCoordinates) return false;
    if (buffer->count == buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity * 2 : 64;
        if (capacity > KMLMaximumCoordinates) capacity = KMLMaximumCoordinates;
        void *allocation = realloc(buffer->values, capacity * sizeof(*buffer->values));
        if (!allocation) return false; // Never lose the old allocation on failure.
        buffer->values = allocation;
        buffer->capacity = capacity;
    }
    buffer->values[buffer->count++] = CLLocationCoordinate2DMake(latitude, longitude);
    return true;
}

@interface KMLGeometry : KMLElement {
    struct {
        int inCoords : 1;
    } flags;
    BOOL coordinateConversionFailed;
    NSUInteger coordinateCount;
    CATAKMLCoordinateScanner coordinateScanner;
    KMLCoordinateBuffer coordinateBuffer;
}
@property(nonatomic, readonly) BOOL coordinateConversionFailed;
@property(nonatomic, readonly) NSUInteger coordinateCount;

- (void)beginCoordinates;
- (void)endCoordinates;
- (void)addCoordinateBytes:(const char *)bytes length:(NSUInteger)length;

// Create and return the corresponding Map Kit MKShape object
// corresponding to this KML Geometry node.
@property(NS_NONATOMIC_IOSONLY, readonly, nullable) MKShape *mapkitShape;

@end

// A KMLPoint element corresponds to an MKAnnotation and MKPinAnnotationView
@interface KMLPoint : KMLGeometry {
    CLLocationCoordinate2D point;
}

@end

@interface KMLLineString : KMLGeometry {
    MKPolyline *parsedLine;
}

@end

@interface KMLPlacemark : KMLElement {
    KMLStyle *style;
    KMLGeometry *geometry;

    NSString *name;

    NSString *styleUrl;

    NSMutableArray<MKShape *> *mkShapes;

    struct {
        int inName : 1;
        int inStyle : 1;
        int inGeometry : 1;
        int inStyleUrl : 1;
    } flags;
}

- (void)beginName;
- (void)endName;

- (void)beginStyleWithIdentifier:(nullable NSString *)ident;
- (void)endStyle;

- (void)beginGeometryOfType:(NSString *)type withIdentifier:(nullable NSString *)ident;
- (void)endGeometry;

- (void)beginStyleUrl;
- (void)endStyleUrl;

// Corresponds to the title property on MKAnnotation
@property(nonatomic, strong, readonly, nullable) NSString *name;

@property(nonatomic, strong, readonly, nullable) KMLGeometry *geometry;

@property(nonatomic, strong, nullable) KMLStyle *style;
@property(nonatomic, strong, readonly, nullable) NSString *styleUrl;

@property(nonatomic) BOOL createsPointAnnotations;
@property(nonatomic, readonly, unsafe_unretained) NSArray<MKShape *> *shapes;

@end

@interface KMLStyleMap : KMLElement {
    NSMutableDictionary *_pairs;
}
@property(nonatomic, readonly, nullable) NSDictionary *pairs;
- (void)addPairKey:(NSString *)key styleUrl:(NSString *)styleUrl;
@end

@interface KMLParser () {
    NSArray<id<MKOverlay>> *_renderOverlays;
    NSArray<id<MKAnnotation>> *_renderPoints;
    NSMapTable<id<MKOverlay>, id> *_renderStyles;
}
@property(nonatomic, strong, readwrite, nullable) NSError *parseError;
@property(nonatomic, readwrite) NSUInteger coordinateCount;
- (void)prepareRenderGeometry;
@end

static void KMLAppendLineGroup(NSArray<MKPolyline *> *lines, KMLStyle *style,
                               NSMutableArray<id<MKOverlay>> *overlays,
                               NSMapTable<id<MKOverlay>, id> *styles) {
    if (lines.count == 0) return;
    id<MKOverlay> overlay =
        lines.count == 1 ? lines.firstObject : [[MKMultiPolyline alloc] initWithPolylines:lines];
    [overlays addObject:overlay];
    [styles setObject:(id)style ?: NSNull.null forKey:overlay];
}

@implementation KMLParser

// After parsing has completed, this method loops over all placemarks that have
// been parsed and looks up their corresponding KMLStyle objects according to
// the placemark's styleUrl property and the global KMLStyle object's identifier.
- (void)assignStyles {
    for (KMLPlacemark *placemark in _placemarks) {
        if (!placemark.style && placemark.styleUrl) {
            // Parser-owned placemarks, styles, and map pairs survive this synchronous pass.
            __unsafe_unretained NSString *styleUrl = placemark.styleUrl;
            if ([styleUrl hasPrefix:@"#"]) {
                NSString *styleID = [styleUrl substringFromIndex:1];
                __unsafe_unretained KMLStyle *style = _styles[styleID];
                // If the style is a StyleMap, resolve it to the "normal" style.
                if ([style isKindOfClass:[KMLStyleMap class]]) {
                    __unsafe_unretained KMLStyleMap *map = (KMLStyleMap *)style;
                    __unsafe_unretained NSString *normalStyleUrl = map.pairs[@"normal"];
                    if ([normalStyleUrl hasPrefix:@"#"]) {
                        NSString *normalID = [normalStyleUrl substringFromIndex:1];
                        style = _styles[normalID];
                    }
                }
                if ([style isKindOfClass:KMLStyle.class]) placemark.style = style;
            }
        }
    }
}

- (instancetype)initWithData:(NSData *)data {
    if (self = [super init]) {
        _includesPointAnnotations = YES;
        _styles = [[NSMutableDictionary alloc] init];
        _placemarks = [[NSMutableArray alloc] init];
        if (data.length == 0 || data.length > KMLMaximumInputBytes) {
            _parseError = [NSError errorWithDomain:@"CATAKMLParser"
                                              code:1
                                          userInfo:@{
                                              NSLocalizedDescriptionKey :
                                                  @"Empty KML or document exceeds the 16 MiB parsing limit."
                                          }];
            _renderOverlays = @[];
            _renderPoints = @[];
            return self;
        }
        _xmlParser = [[NSXMLParser alloc] initWithData:data];
        _xmlParser.shouldProcessNamespaces = YES;

        [_xmlParser setDelegate:self];
    }
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)fileURL {
    if ((self = [super init])) {
        _includesPointAnnotations = YES;
        _styles = [[NSMutableDictionary alloc] init];
        _placemarks = [[NSMutableArray alloc] init];
        NSError *error = nil;
        NSDictionary *attributes = fileURL.isFileURL
                                       ? [NSFileManager.defaultManager attributesOfItemAtPath:fileURL.path
                                                                                        error:&error]
                                       : nil;
        unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
        if (!attributes || size == 0 || size > KMLMaximumInputBytes ||
            ![attributes[NSFileType] isEqual:NSFileTypeRegular]) {
            _parseError =
                error
                    ?: [NSError errorWithDomain:@"CATAKMLParser"
                                           code:1
                                       userInfo:@{
                                           NSLocalizedDescriptionKey :
                                               @"KML must be a nonempty regular local file of at most 16 MiB."
                                       }];
            _renderOverlays = @[];
            _renderPoints = @[];
            return self;
        }
        NSInputStream *stream = [[NSInputStream alloc] initWithURL:fileURL];
        _xmlParser = [[NSXMLParser alloc] initWithStream:stream];
        _xmlParser.shouldProcessNamespaces = YES;
        _xmlParser.delegate = self;
    }
    return self;
}

- (void)parseKML {
    if (!_xmlParser) return;
    BOOL success = [_xmlParser parse];
    if (!success && !self.parseError)
        self.parseError =
            _xmlParser.parserError
                ?: [NSError errorWithDomain:@"CATAKMLParser"
                                       code:3
                                   userInfo:@{
                                       NSLocalizedDescriptionKey : @"The XML parser did not complete."
                                   }];
    _xmlParser.delegate = nil;
    _xmlParser = nil;
    if (success && !self.parseError) {
        [self assignStyles];
        // Materialize on the parser's owning queue. The main-thread handoff
        // receives already-built geometry, not a lazy shape-building job.
        [self prepareRenderGeometry];
    } else {
        _renderOverlays = @[];
        _renderPoints = @[];
        [_styles removeAllObjects];
    }
    _placemarks = nil;
    _placemark = nil;
    _style = nil;
    _styleMap = nil;
    _pairKey = nil;
    _pairStyleUrl = nil;

}

// One pass over owned shapes: no per-placemark overlay/point arrays, no
// duplicate title assignment, and no lazy geometry work on the main thread.
- (void)prepareRenderGeometry {
    NSMutableArray<id<MKOverlay>> *overlays = [[NSMutableArray alloc] init];
    NSMutableArray<id<MKAnnotation>> *points = [[NSMutableArray alloc] init];
    _renderStyles = [[NSMapTable alloc]
        initWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
              valueOptions:NSPointerFunctionsStrongMemory
                  capacity:0];
    NSMutableArray<MKPolyline *> *lines = [[NSMutableArray alloc] init];
    KMLStyle *lineStyle = nil;
    for (KMLPlacemark *placemark in _placemarks) {
        for (MKShape *shape in placemark.shapes) {
            shape.title = placemark.name;
            if ([shape isKindOfClass:MKPolyline.class]) {
                if (lines.count && lineStyle != placemark.style) {
                    KMLAppendLineGroup(lines, lineStyle, overlays, _renderStyles);
                    [lines removeAllObjects];
                }
                lineStyle = placemark.style;
                [lines addObject:(MKPolyline *)shape];
            } else if ([shape isKindOfClass:MKPointAnnotation.class]) {
                [points addObject:(MKPointAnnotation *)shape];
            }
        }
    }
    KMLAppendLineGroup(lines, lineStyle, overlays, _renderStyles);
    _renderOverlays = [overlays copy];
    _renderPoints = [points copy];
}

- (NSArray<id<MKOverlay>> *)overlays {
    return _renderOverlays ?: @[];
}
- (NSArray<id<MKAnnotation>> *)points {
    return _renderPoints ?: @[];
}

- (MKOverlayRenderer *)rendererForOverlay:(id<MKOverlay>)overlay {
    // NSNull records an unstyled owned overlay, so this also tests membership.
    __unsafe_unretained id style = [_renderStyles objectForKey:overlay];
    if (!style) return nil;
    MKOverlayPathRenderer *renderer;
    if ([(NSObject *)overlay isKindOfClass:MKMultiPolyline.class]) {
        renderer = [[MKMultiPolylineRenderer alloc] initWithMultiPolyline:(MKMultiPolyline *)overlay];
    } else if ([(NSObject *)overlay isKindOfClass:MKPolyline.class]) {
        renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
    } else {
        return nil;
    }
    if (style != NSNull.null) [(KMLStyle *)style applyToOverlayPathRenderer:renderer];
    // MapKit owns renderer lifetimes. The parser must not retain their drawing
    // resources after a route is removed from the visible transit layer.
    return renderer;
}

#pragma mark NSXMLParserDelegate

#define ELTYPE(typeName) (NSOrderedSame == [elementName caseInsensitiveCompare:@ #typeName])

- (void)parser:(NSXMLParser *)parser
    didStartElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName
         attributes:(NSDictionary *)attributeDict {
    NSString *ident = attributeDict[@"id"];

    // Get the current style (if any)
    // Borrow from _placemark.style or _style for this synchronous callback.
    // Branches that release/replace those owners do not subsequently use this local.
    __unsafe_unretained KMLStyle *style = _placemark.style ?: _style;

    // Style and sub-elements
    if (ELTYPE(Style)) {
        if (_placemark) {
            [_placemark beginStyleWithIdentifier:ident];
        } else if (ident != nil) {
            _style = [[KMLStyle alloc] initWithIdentifier:ident];
        }
    }
    // New support for StyleMap elements
    else if (ELTYPE(StyleMap)) {
        if (!_placemark && ident != nil) {
            _styleMap = [[KMLStyleMap alloc] initWithIdentifier:ident];
        }
    } else if (ELTYPE(LineStyle)) {
        [style beginLineStyle];
    } else if (ELTYPE(color)) {
        [style beginColor];
    } else if (ELTYPE(width)) {
        [style beginWidth];
    } else if (ELTYPE(outline)) {
        [style beginOutline];
    }
    // Placemark and sub-elements
    else if (ELTYPE(Placemark)) {
        _placemark = [[KMLPlacemark alloc] initWithIdentifier:ident];
        _placemark.createsPointAnnotations = self.includesPointAnnotations;
    } else if (ELTYPE(Name)) {
        [_placemark beginName];
    }
    // For styleUrl, check if we're inside a Pair element
    else if (ELTYPE(styleUrl)) {
        // If we’re within a Placemark, use its styleUrl handling.
        if (_placemark) {
            [_placemark beginStyleUrl];
        }
        // Otherwise, if we’re inside a StyleMap Pair, handle it as a pair.
        else if (_styleMap) {
            _inPairStyleUrl = YES;
            _pairStyleUrl = [[NSMutableString alloc] init];
        }
    }

    else if (ELTYPE(Point) || ELTYPE(LineString)) {
        [_placemark beginGeometryOfType:elementName withIdentifier:ident];
    }
    // Geometry sub-elements
    else if (ELTYPE(coordinates)) {
        [_placemark.geometry beginCoordinates];
    }
    // New handling for Pair elements inside a StyleMap
    else if (ELTYPE(Pair)) {
        if (_styleMap) {
            _inPair = YES;
        }
    } else if (ELTYPE(key)) {
        if (_inPair) {
            _inPairKey = YES;
            _pairKey = [[NSMutableString alloc] init];
        }
    }
}

- (void)parser:(NSXMLParser *)parser
    didEndElement:(NSString *)elementName
     namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qName {
    // Borrow from _placemark.style or _style for this synchronous callback.
    // Branches that release/replace those owners do not subsequently use this local.
    __unsafe_unretained KMLStyle *style = _placemark.style ?: _style;

    if (ELTYPE(Style)) {
        if (_placemark) {
            [_placemark endStyle];
        } else if (_style) {
            // _style owns the identifier until after its last use below.
            __unsafe_unretained NSString *styleID = _style.identifier;
            if (styleID) _styles[styleID] = _style;
            _style = nil;
        }
    } else if (ELTYPE(StyleMap)) {
        if (_styleMap) {
            // _styleMap owns the identifier until after its last use below.
            __unsafe_unretained NSString *styleID = _styleMap.identifier;
            if (styleID) _styles[styleID] = _styleMap;
            _styleMap = nil;
        }
    } else if (ELTYPE(LineStyle)) {
        [style endLineStyle];
    } else if (ELTYPE(color)) {
        [style endColor];
    } else if (ELTYPE(width)) {
        [style endWidth];
    } else if (ELTYPE(outline)) {
        [style endOutline];
    }
    // Placemark and sub-elements
    else if (ELTYPE(Placemark)) {
        if (_placemark) {
            if (_placemark.shapes.count) [_placemarks addObject:_placemark];
            _placemark = nil;
        }
    } else if (ELTYPE(Name)) {
        [_placemark endName];
    }
    // For styleUrl, check context
    else if (ELTYPE(styleUrl)) {
        if (_placemark) {
            [_placemark endStyleUrl];
        } else if (_styleMap) {
            _inPairStyleUrl = NO;
        }
    } else if (ELTYPE(Point) || ELTYPE(LineString)) {
        [_placemark endGeometry];
    }
    // Geometry sub-elements
    else if (ELTYPE(coordinates)) {
        KMLGeometry *geometry = _placemark.geometry;
        [geometry endCoordinates];
        self.coordinateCount += geometry.coordinateCount;
        if (geometry.coordinateConversionFailed || self.coordinateCount > KMLMaximumCoordinates) {
            self.parseError =
                [NSError errorWithDomain:@"CATAKMLParser"
                                    code:2
                                userInfo:@{
                                    NSLocalizedDescriptionKey : @"Malformed KML coordinates, allocation "
                                                                @"failure, or coordinate limit exceeded."
                                }];
            [parser abortParsing];
        }
    }
    // New: finish Pair handling inside StyleMap
    else if (ELTYPE(key)) {
        if (_inPair) {
            _inPairKey = NO;
        }
    } else if (ELTYPE(Pair)) {
        if (_styleMap && _pairKey && _pairStyleUrl) {
            [_styleMap addPairKey:_pairKey styleUrl:_pairStyleUrl];
            _pairKey = nil;
            _pairStyleUrl = nil;
        }
        _inPair = NO;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (_inPairKey) {
        [_pairKey appendString:string];
    } else if (_inPairStyleUrl) {
        [_pairStyleUrl appendString:string];
    } else {
        // The parser owns this node throughout addString:, which does not replace it.
        __unsafe_unretained KMLElement *element =
            _placemark ? (KMLElement *)_placemark : (KMLElement *)_style;
        [element addString:string];
    }
}
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock {
    __unsafe_unretained KMLGeometry *geometry = _placemark.geometry;
    if (geometry.canAddString) {
        // libxml-backed NSXMLParser delivers CDATA as UTF-8. Numeric coordinate
        // syntax is ASCII, so do not round-trip a possibly large CDATA block
        // through NSString just to get the same bytes back.
        [geometry addCoordinateBytes:CDATABlock.bytes length:CDATABlock.length];
        return;
    }
    NSString *text = [[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];
    if (text) [self parser:parser foundCharacters:text];
}

@end

// Begin the implementations of KMLElement and subclasses.  These objects
// act as state machines during parsing time and then once the document is
// fully parsed they act as an object graph for describing the placemarks and
// styles that have been parsed.

@implementation KMLElement

@synthesize identifier;

- (instancetype)initWithIdentifier:(nullable NSString *)ident {
    if (self = [super init]) {
        identifier = [ident copy];
    }
    return self;
}

- (BOOL)canAddString {
    return NO;
}

- (void)addString:(NSString *)str {
    if ([self canAddString]) {
        if (!accum) {
            accum = [[NSMutableString alloc] init];
        }
        [accum appendString:str];
    }
}

@end

@implementation KMLStyle

// The backing ivar retains the parsed color.
- (UIColor *)strokeColor {
    return strokeColor;
}

- (BOOL)canAddString {
    return flags.inColor || flags.inWidth || flags.inOutline;
}

- (void)beginLineStyle {
    flags.inLineStyle = YES;
}

- (void)endLineStyle {
    flags.inLineStyle = NO;
}

- (void)beginColor {
    flags.inColor = YES;
}

- (void)endColor {
    flags.inColor = NO;

    if (flags.inLineStyle) {
        // Parse a KML string based color into a UIColor.  KML colors are agbr hex encoded.

        NSScanner *scanner = [[NSScanner alloc] initWithString:accum ?: @""];
        unsigned color = 0;
        [scanner scanHexInt:&color];

        unsigned a = (color >> 24) & 0x000000FF;
        unsigned b = (color >> 16) & 0x000000FF;
        unsigned g = (color >> 8) & 0x000000FF;
        unsigned r = color & 0x000000FF;

        CGFloat rf = (CGFloat)r / 255.f;
        CGFloat gf = (CGFloat)g / 255.f;
        CGFloat bf = (CGFloat)b / 255.f;
        CGFloat af = (CGFloat)a / 255.f;

        strokeColor = [UIColor colorWithRed:rf green:gf blue:bf alpha:af];
    }

    accum = nil;
}

- (void)beginWidth {
    flags.inWidth = YES;
}

- (void)endWidth {
    flags.inWidth = NO;
    strokeWidth = [accum floatValue];
    accum = nil;
}

- (void)beginOutline {
    flags.inOutline = YES;
}

- (void)endOutline {
    flags.inOutline = NO;
    stroke = [accum boolValue];
    accum = nil;
}

- (void)applyToOverlayPathRenderer:(MKOverlayPathRenderer *)renderer {
    renderer.strokeColor = strokeColor;
    renderer.lineWidth = strokeWidth;
}

@end

@implementation KMLGeometry
@synthesize coordinateConversionFailed, coordinateCount;

- (void)dealloc {
    free(coordinateBuffer.values);
}

- (BOOL)canAddString {
    return flags.inCoords;
}

- (void)beginCoordinates {
    flags.inCoords = YES;
    free(coordinateBuffer.values);
    coordinateBuffer = (KMLCoordinateBuffer){0};
    coordinateScanner = (CATAKMLCoordinateScanner){0};
    coordinateCount = 0;
    coordinateConversionFailed = NO;
}

- (void)addCoordinateBytes:(const char *)bytes length:(NSUInteger)length {
    if (!flags.inCoords || coordinateConversionFailed) return;
    coordinateConversionFailed = CATAKMLScanBytes(&coordinateScanner, bytes, length, KMLStoreCoordinate,
                                                  &coordinateBuffer) != CATAKMLScanOK;
}

- (void)addString:(NSString *)str {
    if (!flags.inCoords || coordinateConversionFailed) return;
    // NSXMLParser can split even the middle of a number across callbacks.
    // Keep only the unfinished tuple plus the C coordinate buffer, not a large
    // accumulated NSString, tuple NSArray, or NSScanner per coordinate.
    CFStringRef string = (__bridge CFStringRef)str;
    CFIndex length = CFStringGetLength(string);
    // These Get...Ptr functions borrow existing storage; they do not request a
    // temporary encoded copy. A NULL result takes the bounded stack path.
    const char *ascii = CFStringGetCStringPtr(string, kCFStringEncodingASCII);
    if (ascii) {
        coordinateConversionFailed = CATAKMLScanBytes(&coordinateScanner, ascii, (size_t)length,
                                                      KMLStoreCoordinate, &coordinateBuffer) != CATAKMLScanOK;
        return;
    }
    const UniChar *direct = CFStringGetCharactersPtr(string);
    if (direct) {
        coordinateConversionFailed = CATAKMLScanUTF16(&coordinateScanner, direct, (size_t)length,
                                                      KMLStoreCoordinate, &coordinateBuffer) != CATAKMLScanOK;
        return;
    }
    UniChar units[512]; // 1 KiB, reused even for a very large parser callback.
    for (CFIndex offset = 0; offset < length && !coordinateConversionFailed;) {
        CFIndex count = MIN((CFIndex)(sizeof(units) / sizeof(units[0])), length - offset);
        CFStringGetCharacters(string, CFRangeMake(offset, count), units);
        coordinateConversionFailed = CATAKMLScanUTF16(&coordinateScanner, units, (size_t)count,
                                                      KMLStoreCoordinate, &coordinateBuffer) != CATAKMLScanOK;
        offset += count;
    }
}

- (void)endCoordinates {
    flags.inCoords = NO;
    CATAKMLScanStatus status =
        CATAKMLFlushTuple(&coordinateScanner, KMLStoreCoordinate, &coordinateBuffer);
    coordinateConversionFailed = status != CATAKMLScanOK;
    coordinateCount = coordinateBuffer.count;
}

- (MKShape *)mapkitShape {
    return nil;
}
@end

@implementation KMLPoint
- (void)beginCoordinates {
    [super beginCoordinates];
    coordinateBuffer.singleOnly = true;
}
- (void)endCoordinates {
    [super endCoordinates];
    coordinateConversionFailed = coordinateConversionFailed || coordinateCount != 1;
    if (!coordinateConversionFailed) point = coordinateBuffer.single;
    free(coordinateBuffer.values);
    coordinateBuffer = (KMLCoordinateBuffer){0};
}

- (MKShape *)mapkitShape {
    if (coordinateConversionFailed || coordinateCount != 1) return nil;
    MKPointAnnotation *annotation = [[MKPointAnnotation alloc] init];
    annotation.coordinate = point;
    return annotation;
}
@end

@implementation KMLLineString
- (void)endCoordinates {
    [super endCoordinates];
    coordinateConversionFailed = coordinateConversionFailed || coordinateCount < 2;
    if (!coordinateConversionFailed) {
        parsedLine = [MKPolyline polylineWithCoordinates:coordinateBuffer.values
                                                   count:coordinateBuffer.count];
        if (!parsedLine) coordinateConversionFailed = YES;
    }
    // Release at </coordinates>, not at </LineString> or at end of the document.
    free(coordinateBuffer.values);
    coordinateBuffer = (KMLCoordinateBuffer){0};
}
- (MKShape *)mapkitShape {
    return parsedLine;
}
@end

@implementation KMLPlacemark

@synthesize style, styleUrl, geometry, name;

- (BOOL)canAddString {
    return flags.inName || flags.inStyleUrl;
}

- (void)addString:(NSString *)str {
    if (flags.inStyle) {
        [style addString:str];
    } else if (flags.inGeometry) {
        [geometry addString:str];
    } else {
        [super addString:str];
    }
}

- (void)beginName {
    flags.inName = YES;
}

- (void)endName {
    flags.inName = NO;
    name = [accum copy];
    accum = nil;
}

- (void)beginStyleUrl {
    flags.inStyleUrl = YES;
}

- (void)endStyleUrl {
    flags.inStyleUrl = NO;
    styleUrl = [accum stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    accum = nil;
}

- (void)beginStyleWithIdentifier:(nullable NSString *)ident {
    flags.inStyle = YES;
    style = [[KMLStyle alloc] initWithIdentifier:ident];
}

- (void)endStyle {
    flags.inStyle = NO;
}

- (void)beginGeometryOfType:(NSString *)elementName withIdentifier:(nullable NSString *)ident {
    flags.inGeometry = YES;
    if (ELTYPE(Point)) {
        geometry = [[KMLPoint alloc] initWithIdentifier:ident];
    } else if (ELTYPE(LineString)) {
        geometry = [[KMLLineString alloc] initWithIdentifier:ident];
    }
}

- (void)endGeometry {
    flags.inGeometry = NO;
    MKShape *shape = (!self.createsPointAnnotations && [geometry isKindOfClass:KMLPoint.class])
                         ? nil
                         : geometry.mapkitShape;
    if (shape) {
        if (!mkShapes) mkShapes = [NSMutableArray array];
        [mkShapes addObject:shape];
    }
    // Keep all disconnected MultiGeometry children; discard raw coordinates
    // immediately after MapKit has made its geometry copy.
    geometry = nil;
}

- (NSArray<MKShape *> *)shapes {
    return mkShapes ?: @[];
}

@end

@implementation KMLStyleMap
- (instancetype)initWithIdentifier:(nullable NSString *)ident {
    if (self = [super initWithIdentifier:ident]) {
        _pairs = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)addPairKey:(NSString *)key styleUrl:(NSString *)styleUrl {
    if (key && styleUrl) {
        // Dictionary insertion copies the key; freeze the caller's URL value too.
        NSString *trimmedKey =
            [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        _pairs[trimmedKey] =
            [styleUrl stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
}

@synthesize pairs = _pairs;
@end
