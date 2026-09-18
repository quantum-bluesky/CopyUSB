#include "xercesc.h"
#include <xercesc/parsers/XercesDOMParser.hpp>
#include <xercesc/framework/MemBufInputSource.hpp>
#include <xercesc/dom/DOM.hpp>
#include <cstring>
#include <iostream>
int main() {
    try {
        Xercesc::Initialize();
        {
            const char xml[] = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><root>Ti\xE1\xBA\xBFng Vi\xE1\xBB\x87t</root>";
            xercesc::MemBufInputSource input(reinterpret_cast<const XMLByte*>(xml), sizeof(xml)-1, "smoke", false);
            xercesc::XercesDOMParser parser;
            parser.setValidationScheme(xercesc::XercesDOMParser::Val_Never);
            parser.parse(input);
            if (parser.getErrorCount() || !parser.getDocument()->getDocumentElement()) return 2;
            uint8* text = Xercesc::TranscodeToUTF8(parser.getDocument()->getDocumentElement()->getTextContent());
            const bool valid = std::strcmp(reinterpret_cast<char*>(text), "Ti\xE1\xBA\xBFng Vi\xE1\xBB\x87t") == 0;
            delete[] text;
            if (!valid) return 3;
        }
        Xercesc::Terminate();
        std::cout << "PASS: Xerces static runtime, XML parse and Vietnamese UTF-8 round trip" << std::endl;
        return 0;
    } catch (...) { std::cerr << "XML smoke test failed" << std::endl; return 1; }
}
